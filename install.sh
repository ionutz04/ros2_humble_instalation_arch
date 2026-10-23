#!/usr/bin/env bash
# Install ROS 2 Humble + Gazebo Classic 11 + gazebo_ros_pkgs on Arch / CachyOS.
#
# Everything is built with GCC 15 (GCC 16 defaults to C++20, which breaks this
# code base). Patched package recipes for current Arch libraries are in
# ./recipes, see README.md for what each fix is about.
#
# Usage:  ./install.sh [--bashrc]
#   --bashrc   append the required 'source' lines to ~/.bashrc
#
# Environment overrides:
#   WS         ROS workspace for gazebo_ros_pkgs   (default: ~/ros2_gazebo_ws)
#   BUILD_DIR  where packages are built             (default: ~/.cache/ros2-humble-arch)
#
# Safe to re-run: installed packages are skipped, built packages are reused.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${WS:-$HOME/ros2_gazebo_ws}"
BUILD_DIR="${BUILD_DIR:-$HOME/.cache/ros2-humble-arch}"
EDIT_BASHRC=0
[[ ${1:-} == --bashrc ]] && EDIT_BASHRC=1

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[[ $EUID -ne 0 ]] || die "run as a normal user (sudo is called when needed)"
command -v pacman >/dev/null || die "pacman not found, this script is for Arch-based systems"
command -v yay >/dev/null    || die "yay not found, install it first: https://github.com/Jguer/yay"
locale | grep -qiE 'LANG=.*utf-?8' || die "your locale must be UTF-8 (required by the ROS 2 build)"
if pacman -Qq gz-tools2 &>/dev/null; then
  die "gz-tools2 (Gazebo Harmonic) is installed and conflicts with Gazebo Classic over /usr/bin/gz.
       Remove it first:  sudo pacman -Rns gz-tools2"
fi

# A sourced ROS environment makes CMake pick ROS's bundled ignition-math6
# instead of the system one, so the system packages are built without it.
unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH \
      PYTHONPATH PKG_CONFIG_PATH ROS_DISTRO ROS_VERSION ROS_PYTHON_VERSION
export MAKEPKG_CONF="$REPO/recipes/makepkg-gz.conf"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
mkdir -p "$BUILD_DIR"

# Build (if needed) and install one package. Uses the patched recipe from
# ./recipes when there is one, otherwise the recipe from the AUR.
aur_install() {
  local name=$1 dir="$BUILD_DIR/$1" pkg
  if pacman -Qq "$name" &>/dev/null; then
    echo "$name already installed"
    return
  fi
  step "Installing $name"
  if [[ -d $REPO/recipes/$name ]]; then
    mkdir -p "$dir"
    cp -r "$REPO/recipes/$name/." "$dir/"
  elif [[ ! -d $dir ]]; then
    (cd "$BUILD_DIR" && yay -G "$name")
  fi
  cd "$dir"
  pkg=$(makepkg --packagelist | grep "/$name-[0-9]" | head -1)
  [[ -f $pkg ]] || makepkg -Cs --nocheck --noconfirm
  sudo pacman -U --needed --noconfirm "$pkg"
}

# ---------------------------------------------------------------- toolchain
step "Toolchain"
missing=$(pacman -T base-devel git gcc15 cmake || true)
if [[ -n $missing ]]; then
  sudo pacman -S --needed --noconfirm $missing
else
  echo "base-devel git gcc15 cmake already installed"
fi

# ---------------------------------------------------------------- ROS 2
step "ROS 2 Humble"
if ! pacman -Qq ros2-humble &>/dev/null; then
  yay -S --needed --noconfirm --asdeps ros2-arch-deps
  mkdir -p "$BUILD_DIR/ros2-humble"
  cp -r "$REPO/recipes/ros2-humble/." "$BUILD_DIR/ros2-humble/"
  (cd "$BUILD_DIR/ros2-humble" && makepkg -si --noconfirm)
else
  echo "ros2-humble already installed"
fi

# ---------------------------------------------------------------- Gazebo 11
# Installed one by one, in this order: yay cannot resolve versioned provides
# such as 'ignition-math=6', so each package's deps must be installed first.
for p in ignition-cmake-2 ignition-utils-1 ignition-tools-1 ignition-math-6 \
         urdfdom ignition-msgs-5 ignition-common-3 ogre-1.9 sdformat-9 \
         ignition-transport-8 ignition-fuel_tools-4 gazebo; do
  aur_install "$p"
done

# ---------------------------------------------------------------- workspace
step "ROS workspace in $WS: gazebo_ros_pkgs + deps"
mkdir -p "$WS/src"
clone() { [[ -d $WS/src/$2 ]] || git clone -b "$1" "$3" "$WS/src/$2"; }
clone ros2         gazebo_ros_pkgs       https://github.com/ros-simulation/gazebo_ros_pkgs.git
clone humble       vision_opencv         https://github.com/ros-perception/vision_opencv.git
clone humble-devel angles                https://github.com/ros/angles.git
clone ros2-humble  diagnostics           https://github.com/ros/diagnostics.git
clone dashing      teleop_twist_keyboard https://github.com/ros2/teleop_twist_keyboard.git
# cv_bridge for Humble does not know OpenCV 5
if git -C "$WS/src/vision_opencv" apply --check "$REPO/recipes/cv_bridge-opencv5.patch" 2>/dev/null; then
  git -C "$WS/src/vision_opencv" apply "$REPO/recipes/cv_bridge-opencv5.patch"
fi

(
  cd "$WS"
  set +u
  source /opt/ros/humble/setup.bash
  set -u
  export CC=gcc-15 CXX=g++-15
  # ignition-math6_DIR: the system copy Gazebo is built against,
  # not the older one bundled in /opt/ros/humble
  colcon build --base-paths src \
    --packages-up-to gazebo_ros_pkgs teleop_twist_keyboard \
    --cmake-args -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release -Wno-dev \
    -Dignition-math6_DIR=/usr/lib/cmake/ignition-math6 \
    -DCMAKE_CXX_FLAGS="--include=cstdint -isystem /usr/include/eigen3"
)

# ---------------------------------------------------------------- done
SOURCES="source /opt/ros/humble/setup.bash
source /usr/share/gazebo/setup.sh
source $WS/install/setup.bash"

step "Done"
if ((EDIT_BASHRC)); then
  while read -r line; do
    grep -qxF "$line" ~/.bashrc || echo "$line" >> ~/.bashrc
  done <<< "$SOURCES"
  echo "Added the environment to ~/.bashrc, open a new terminal to use it."
else
  echo "Add to ~/.bashrc (or run in each new terminal):"
  sed 's/^/  /' <<< "$SOURCES"
fi
echo
echo "Verify the installation with:  WS=$WS $REPO/test.sh"
