# ROS 2 Humble + Gazebo Classic 11 on Arch Linux

One script that installs **ROS 2 Humble**, **Gazebo Classic 11** and **`gazebo_ros_pkgs`**
on a current Arch / CachyOS system, and one script that checks that the whole stack works:
Gazebo starts through ROS, a robot is spawned and driven with `/cmd_vel`.

It gives you the same setup as `sudo apt install ros-humble-gazebo-ros-pkgs` on
Ubuntu 22.04, so tutorials and course material written for Ubuntu work as written:

```bash
ros2 launch gazebo_ros gazebo.launch.py
ros2 run gazebo_ros spawn_entity.py -entity my_car -file car.sdf -x 0 -y 0 -z 0.1
ros2 run teleop_twist_keyboard teleop_twist_keyboard
```

## Why this exists

The AUR packages (`ros2-humble`, `gazebo`, the `ignition-*` libraries) no longer
build on a rolling-release system. ROS 2 Humble and Gazebo 11 were written for
Ubuntu 22.04's 2022 libraries, while Arch now ships GCC 16, Boost 1.92,
protobuf 36, OpenCV 5 and Eigen 5. Plain `yay -S ros2-humble gazebo` fails in a
dozen places. This repo contains the fixes, tested end to end.

## Quick start

Requirements: an Arch-based system, [`yay`](https://github.com/Jguer/yay), a
UTF-8 locale, about 30 GB of free disk space, and a few hours of compile time.

```bash
git clone <this-repo> ros2_humble_instalation_arch
cd ros2_humble_instalation_arch
./install.sh --bashrc      # asks for your sudo password when installing packages
# open a new terminal, then:
./test.sh
```

`--bashrc` adds the three `source` lines below to `~/.bashrc`. Without it, the
script prints them and you add them yourself:

```bash
source /opt/ros/humble/setup.bash
source /usr/share/gazebo/setup.sh
source ~/ros2_gazebo_ws/install/setup.bash
```

`install.sh` can be re-run at any time. Installed packages are skipped and
already built packages are reused, so after a failure it continues where it
stopped.

### Options

| Variable    | Default                     | Meaning                                           |
|-------------|-----------------------------|---------------------------------------------------|
| `WS`        | `~/ros2_gazebo_ws`          | colcon workspace for `gazebo_ros_pkgs`            |
| `BUILD_DIR` | `~/.cache/ros2-humble-arch` | where packages are compiled (several GB)          |

Example: `WS=~/robot_ws ./install.sh`, then `WS=~/robot_ws ./test.sh`.

> Builds happen in `BUILD_DIR`, outside this repo, so the repo can sit in a
> synced folder (Nextcloud, Dropbox) without uploading gigabytes of build files.

## What gets installed

| Step | Packages | Installed to |
|------|----------|--------------|
| Toolchain | `gcc15`, `base-devel`, `git`, `cmake` | system (pacman) |
| ROS 2 | `ros2-humble` (patched AUR recipe) | `/opt/ros/humble` |
| Gazebo deps | `ignition-cmake-2`, `ignition-utils-1`, `ignition-tools-1`, `ignition-math-6`, `urdfdom`, `ignition-msgs-5`, `ignition-common-3`, `ogre-1.9`, `sdformat-9`, `ignition-transport-8`, `ignition-fuel_tools-4` | system (pacman) |
| Gazebo | `gazebo` 11.14.0 (patched) | system (pacman) |
| ROS bridge | `gazebo_ros_pkgs`, `cv_bridge`, `angles`, `diagnostic_updater`, `teleop_twist_keyboard` | `$WS` (colcon) |

The Gazebo stack is installed in that order, one package at a time, because yay
can't resolve versioned dependencies such as `ignition-math=6`.

## What `test.sh` checks

Runs without a display, takes about a minute, and exits non-zero on failure.

1. `gzserver` and the ROS packages are installed
2. ROS 2 messaging works (`talker` → `/chatter`)
3. `ros2 launch gazebo_ros gzserver.launch.py` starts and `/spawn_entity` appears
4. Gazebo publishes `/clock`
5. `spawn_entity.py` spawns a small differential-drive robot
6. Publishing to `/cmd_vel` moves the robot, and `/odom` shows it travelled > 0.3 m

It uses `ROS_DOMAIN_ID=77` and `ROS_LOCALHOST_ONLY=1`, so it doesn't interfere
with other ROS machines on your network.

Expected output:

```
PASS gzserver up, /spawn_entity available
PASS /clock published
PASS spawn_entity.py test_bot
PASS robot drove on /cmd_vel: x -2.4e-05 -> 1.997
All checks passed.
```

## The fixes, and why they are needed

All builds use GCC 15 and [`recipes/makepkg-gz.conf`](recipes/makepkg-gz.conf),
passed through `MAKEPKG_CONF`. Your `/etc/makepkg.conf` is not modified.

| Problem on current Arch | Affects | Fix |
|---|---|---|
| GCC 16 defaults to C++20, e.g. `operator<<(ostream, char16_t)` is deleted | everything (first seen in vendored gtest) | build with `gcc-15` / `g++-15` |
| GCC 15 no longer includes `<cstdint>` transitively (`uint32_t` not declared) | ROS 2, `ignition-common-3` | `--include=cstdint` |
| Eigen 5's CMake config no longer sets `EIGEN3_INCLUDE_DIRS` | `rviz_rendering` | `-isystem /usr/include/eigen3` |
| A sourced ROS environment makes CMake use ROS's older bundled `ignition-math6` (`gz/math/*.hh` not found) | Gazebo deps | build with the ROS variables unset; workspace uses `-Dignition-math6_DIR=/usr/lib/cmake/ignition-math6` |
| protobuf ≥ 30: `name()` / `GetTypeName()` return `std::string_view` | `ignition-msgs-5`, `ignition-transport-8`, `gazebo` | wrap in `std::string(...)` |
| protobuf ≥ 30 forbids `internal::DownCast` on messages | `ignition-transport-8` | `google::protobuf::DownCastMessage<T>` |
| `ruby2.7` (AUR) doesn't build against OpenSSL 3 | `sdformat-9` | system Ruby; `File.exists?` → `File.exist?` (removed in Ruby 3.2) |
| Boost 1.87 removed `io_service`, `resolver::query`, `resolver::iterator`, `address_v4::from_string` / `to_ulong` | `gazebo` transport | `io_context`, `executor_work_guard`, `resolve(...).begin()`, `make_address_v4`, `to_uint` |
| Boost 1.85 removed `path::branch_path`, `filesystem::basename/extension` | `gazebo` | `parent_path`, `filename` |
| Boost 1.86 changed `sha1::get_digest` to 20 bytes | `gazebo` | new digest type; output verified identical to `sha1sum` |
| Graphviz dropped the `TRUE` macro | `gazebo` GUI | `1` |
| The AUR recipe's `graphviz9.patch` is already in 11.14.0, so `prepare()` fails | `gazebo` | patch dropped |
| Crash when `GAZEBO_MODEL_DATABASE_URI` is empty (`operator[]` on an empty string) | `gazebo` | empty check |
| OpenCV 5 removed the legacy `types_c.h` headers | `cv_bridge` | accept OpenCV 5, use the OpenCV 4 code path |
| New setuptools rejects `--editable` | `colcon --symlink-install` | don't use `--symlink-install` |

### Repository layout

```
install.sh                         installer
test.sh                            end-to-end test
recipes/
  makepkg-gz.conf                  GCC 15 + flags for every package build
  ros2-humble/                     AUR recipe + GCC 15 / Eigen 5 changes
  ignition-msgs-5/PKGBUILD         + protobuf string_view fix in prepare()
  ignition-transport-8/            + protobuf-string_view.patch, DownCastMessage
  sdformat-9/PKGBUILD              system ruby, Ruby 3.2 fix
  gazebo/                          + gazebo11-arch.patch (Boost, protobuf, graphviz)
  cv_bridge-opencv5.patch          applied to the vision_opencv checkout
```

Packages without changes (`ignition-common-3`, `ogre-1.9`, `urdfdom`, …) are
downloaded from the AUR with `yay -G` and built with the same GCC 15 config.

## Tested with

| Component | Version |
|---|---|
| OS | CachyOS, kernel 6.18 |
| System GCC / build GCC | 16.2.1 / 15.3.0 |
| Boost | 1.92.0 |
| protobuf | 36.1 |
| OpenCV | 5.0.0 |
| Eigen | 5.0.1 |
| Python | 3.14 |
| Ruby | 3.4 |
| ROS 2 | Humble, release 2026-02-20 |
| Gazebo | Classic 11.14.0 |

A future `pacman -Syu` that updates Boost, protobuf or OpenCV can break these
packages again. Run `./test.sh` after big updates; if it fails, rebuild the
affected package (`sudo pacman -R <pkg>`, then `./install.sh`).

## Troubleshooting

**`gz-tools2 ... conflicts`**
Gazebo Harmonic packages own `/usr/bin/gz`, which Gazebo Classic also installs.
Remove Harmonic first: `sudo pacman -Rns gz-tools2 gz-plugin2 gz-math7 gz-utils2 gz-cmake3`.

**`colcon build: Duplicate package names not supported`**
colcon found package sources outside `src/`. The workspace build uses
`--base-paths src`; don't put build folders inside the workspace.

**`cannot import name 'printed_strlen'` traceback from colcon**
Harmless: a version mismatch between two colcon plugins in Arch's packages.
Builds are unaffected.

**Gazebo hangs at start or can't find `model://...`**
Make sure `/usr/share/gazebo/setup.sh` is sourced. It sets the model,
resource and plugin paths. To skip the online model database entirely:
`export GAZEBO_MODEL_DATABASE_URI=`.

**A package fails to build**
Re-run `./install.sh`, which continues from the failed package. The
build output is in `$BUILD_DIR/<package>/src/`.

## Known limitations

- `test.sh` runs headless, so the Gazebo GUI (`gzclient`) and camera sensors
  aren't covered by the automated test. Both worked in manual testing.
- Gazebo Classic reached end of life in January 2025. For new projects, consider
  ROS 2 Jazzy with Gazebo Harmonic. This repo is for courses and code that
  need Humble + Gazebo 11.

## Uninstall

```bash
sudo pacman -Rns gazebo ignition-fuel_tools-4 ignition-transport-8 sdformat-9 ogre-1.9 \
  ignition-common-3 ignition-msgs-5 urdfdom ignition-math-6 ignition-tools-1 \
  ignition-utils-1 ignition-cmake-2 ros2-humble
rm -rf ~/ros2_gazebo_ws ~/.cache/ros2-humble-arch
```

Then remove the `source` lines from `~/.bashrc`.

## Credits

The package recipes are based on the AUR packages by their maintainers and
contributors (listed in each `PKGBUILD`). ROS 2 is by Open Robotics and the ROS
community; Gazebo by Open Robotics.
