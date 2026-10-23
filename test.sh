#!/usr/bin/env bash
# End-to-end test of the ROS 2 Humble + Gazebo Classic setup:
# headless gzserver via gazebo_ros, spawn a diff-drive robot, drive it with
# /cmd_vel and check that /odom reports movement.
#
# Usage:  ./test.sh            (WS=<workspace> ./test.sh for a non-default workspace)
# No display needed; takes about a minute. Exit code 0 = all checks passed.
set -u

WS="${WS:-$HOME/ros2_gazebo_ws}"
TMP=$(mktemp -d)
LAUNCH_PID=""
FAILED=0

pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=1; }

cleanup() {
  [[ -n $LAUNCH_PID ]] && kill -INT -- -"$LAUNCH_PID" 2>/dev/null
  sleep 2
  pkill -f gzserver 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Wait up to $1 seconds for command $2... to succeed
wait_for() {
  local t=$1; shift
  for ((i = 0; i < t; i++)); do "$@" &>/dev/null && return 0; sleep 1; done
  return 1
}

set +u
source /opt/ros/humble/setup.bash
source "$WS/install/setup.bash"
# Gazebo's resource/model/plugin paths
[[ -f /usr/share/gazebo/setup.sh ]] && source /usr/share/gazebo/setup.sh
set -u
# Isolate from other ROS machines on the network
export ROS_DOMAIN_ID=77 ROS_LOCALHOST_ONLY=1

echo "== Installation"
command -v gzserver >/dev/null && pass "gzserver: $(gzserver --version 2>&1 | grep -o 'version [0-9.]*' | head -1)" \
  || fail "gzserver not found"
for p in rclcpp gazebo_ros gazebo_plugins gazebo_msgs cv_bridge teleop_twist_keyboard; do
  ros2 pkg prefix "$p" &>/dev/null && pass "ROS package $p" || fail "ROS package $p missing"
done
((FAILED)) && { echo "Installation incomplete, skipping simulation test."; exit 1; }

echo "== ROS 2 talker/listener"
timeout 10 ros2 run demo_nodes_cpp talker &>/dev/null &
if timeout 10 ros2 topic echo --once /chatter &>/dev/null; then
  pass "talker -> /chatter"
else
  fail "no message on /chatter"
fi
wait 2>/dev/null

echo "== Gazebo (headless)"
cat > "$TMP/robot.sdf" <<'EOF'
<?xml version="1.0"?>
<sdf version="1.6">
  <model name="test_bot">
    <link name="base_link">
      <pose>0 0 0.1 0 0 0</pose>
      <inertial><mass>5</mass>
        <inertia><ixx>0.05</ixx><iyy>0.08</iyy><izz>0.1</izz></inertia></inertial>
      <collision name="body"><geometry><box><size>0.4 0.3 0.1</size></box></geometry></collision>
      <visual name="body"><geometry><box><size>0.4 0.3 0.1</size></box></geometry></visual>
      <collision name="caster">
        <pose>-0.15 0 -0.05 0 0 0</pose>
        <geometry><sphere><radius>0.05</radius></sphere></geometry>
        <surface><friction><ode><mu>0</mu><mu2>0</mu2></ode></friction></surface>
      </collision>
    </link>
    <link name="left_wheel">
      <pose>0.1 0.2 0.1 0 0 0</pose>
      <inertial><mass>0.5</mass>
        <inertia><ixx>0.001</ixx><iyy>0.002</iyy><izz>0.001</izz></inertia></inertial>
      <collision name="c"><pose>0 0 0 1.5708 0 0</pose>
        <geometry><cylinder><radius>0.1</radius><length>0.05</length></cylinder></geometry></collision>
      <visual name="v"><pose>0 0 0 1.5708 0 0</pose>
        <geometry><cylinder><radius>0.1</radius><length>0.05</length></cylinder></geometry></visual>
    </link>
    <link name="right_wheel">
      <pose>0.1 -0.2 0.1 0 0 0</pose>
      <inertial><mass>0.5</mass>
        <inertia><ixx>0.001</ixx><iyy>0.002</iyy><izz>0.001</izz></inertia></inertial>
      <collision name="c"><pose>0 0 0 1.5708 0 0</pose>
        <geometry><cylinder><radius>0.1</radius><length>0.05</length></cylinder></geometry></collision>
      <visual name="v"><pose>0 0 0 1.5708 0 0</pose>
        <geometry><cylinder><radius>0.1</radius><length>0.05</length></cylinder></geometry></visual>
    </link>
    <joint name="left_wheel_joint" type="revolute">
      <parent>base_link</parent><child>left_wheel</child><axis><xyz>0 1 0</xyz></axis>
    </joint>
    <joint name="right_wheel_joint" type="revolute">
      <parent>base_link</parent><child>right_wheel</child><axis><xyz>0 1 0</xyz></axis>
    </joint>
    <plugin name="diff_drive" filename="libgazebo_ros_diff_drive.so">
      <left_joint>left_wheel_joint</left_joint>
      <right_joint>right_wheel_joint</right_joint>
      <wheel_separation>0.4</wheel_separation>
      <wheel_diameter>0.2</wheel_diameter>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_link</robot_base_frame>
    </plugin>
  </model>
</sdf>
EOF

# gzserver only: no GUI needed for the test. setsid gives a process group to kill.
setsid ros2 launch gazebo_ros gzserver.launch.py > "$TMP/gazebo.log" 2>&1 &
LAUNCH_PID=$!

if wait_for 60 bash -c 'ros2 service list | grep -q /spawn_entity'; then
  pass "gzserver up, /spawn_entity available"
else
  fail "gzserver did not come up (log below)"; tail -30 "$TMP/gazebo.log"; exit 1
fi

timeout 10 ros2 topic echo --once /clock &>/dev/null && pass "/clock published" || fail "no /clock"

if timeout 30 ros2 run gazebo_ros spawn_entity.py -entity test_bot -file "$TMP/robot.sdf" \
     -x 0 -y 0 -z 0.01 > "$TMP/spawn.log" 2>&1; then
  pass "spawn_entity.py test_bot"
else
  fail "spawn failed"; cat "$TMP/spawn.log"; exit 1
fi

odom_x() { timeout 10 ros2 topic echo --once --field pose.pose.position.x /odom 2>/dev/null | head -1; }

if ! wait_for 15 bash -c 'timeout 5 ros2 topic echo --once /odom'; then
  fail "no /odom from diff drive plugin"; exit 1
fi
x0=$(odom_x)
timeout 4 ros2 topic pub -r 10 /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.5}}" &>/dev/null
x1=$(odom_x)
if [[ -n $x0 && -n $x1 ]] && awk -v a="$x0" -v b="$x1" 'BEGIN { exit !(b - a > 0.3) }'; then
  pass "robot drove on /cmd_vel: x $x0 -> $x1"
else
  fail "robot did not move as expected: x '$x0' -> '$x1'"
fi

echo
if ((FAILED)); then
  echo "Some checks failed."; exit 1
else
  echo "All checks passed. Gazebo GUI: ros2 launch gazebo_ros gazebo.launch.py"
fi
