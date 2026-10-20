cmake_minimum_required(VERSION 3.21)
project(omaremote-native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREERDP REQUIRED IMPORTED_TARGET freerdp3 freerdp-client3 winpr3)

# RDP sessions: one connection per process, drawn into shared memory for a tab.
# The link to the UI every session process shares: socket, prompts, shared-memory framebuffer.
add_library(omaremote-link STATIC common/link.cpp)
target_compile_options(omaremote-link PRIVATE -Wall -Wextra)

add_executable(omaremote-rdp rdp/main.cpp rdp/gfxguard.cpp)
target_link_libraries(omaremote-rdp PRIVATE omaremote-link PkgConfig::FREERDP)
target_compile_options(omaremote-rdp PRIVATE -Wall -Wextra -Wno-unused-parameter)
add_executable(rdp-gfx-test rdp/gfxguard-test.cpp rdp/gfxguard.cpp)
target_link_libraries(rdp-gfx-test PRIVATE omaremote-link PkgConfig::FREERDP)
target_compile_options(rdp-gfx-test PRIVATE -Wall -Wextra)

# VNC sessions, on libvncclient.
pkg_check_modules(VNC REQUIRED IMPORTED_TARGET libvncclient)
add_executable(omaremote-vnc vnc/main.cpp)
target_link_libraries(omaremote-vnc PRIVATE omaremote-link PkgConfig::VNC)
target_compile_options(omaremote-vnc PRIVATE -Wall -Wextra -Wno-unused-parameter)

# SSH sessions: ssh in a pseudo-terminal, libvterm for the screen, Qt (offscreen) to draw it.
pkg_check_modules(VTERM REQUIRED IMPORTED_TARGET vterm)
pkg_check_modules(XKB REQUIRED IMPORTED_TARGET xkbcommon)
find_package(Qt6 6.5 REQUIRED COMPONENTS Gui)
add_executable(omaremote-ssh ssh/main.cpp)
target_link_libraries(omaremote-ssh PRIVATE omaremote-link Qt6::Gui PkgConfig::VTERM PkgConfig::XKB)
target_compile_options(omaremote-ssh PRIVATE -Wall -Wextra -Wno-unused-parameter)

# Gliff sessions (Omarchy desktops over ssh, github.com/omacom/gliff): its protocol by hand, H.264
# through libavcodec (VA-API when it works). gliff-proto-test prints the encodings tests/test_gliff.py checks.
pkg_check_modules(AV REQUIRED IMPORTED_TARGET libavcodec libavutil)
# Decoded surfaces handed to the UI as dmabufs: libva's export, libdrm's format codes.
pkg_check_modules(VA REQUIRED IMPORTED_TARGET libva libdrm)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)
pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
# The clipboard, through ext-data-control (generated here).
set(DATA_CONTROL_XML ${WAYLAND_PROTOCOLS_DIR}/staging/ext-data-control/ext-data-control-v1.xml)
set(PROTOCOL_GEN ${CMAKE_CURRENT_BINARY_DIR}/wayland)
add_custom_command(
  OUTPUT ${PROTOCOL_GEN}/ext-data-control-v1-client-protocol.h ${PROTOCOL_GEN}/ext-data-control-v1-protocol.c
  COMMAND ${CMAKE_COMMAND} -E make_directory ${PROTOCOL_GEN}
  COMMAND ${WAYLAND_SCANNER} client-header ${DATA_CONTROL_XML} ${PROTOCOL_GEN}/ext-data-control-v1-client-protocol.h
  COMMAND ${WAYLAND_SCANNER} private-code ${DATA_CONTROL_XML} ${PROTOCOL_GEN}/ext-data-control-v1-protocol.c
  DEPENDS ${DATA_CONTROL_XML})
add_executable(omaremote-gliff gliff/main.cpp gliff/askpass.cpp gliff/seat.cpp gliff/clipboard.cpp
               ${PROTOCOL_GEN}/ext-data-control-v1-client-protocol.h ${PROTOCOL_GEN}/ext-data-control-v1-protocol.c)
target_include_directories(omaremote-gliff PRIVATE ${PROTOCOL_GEN})
find_package(OpenMP REQUIRED COMPONENTS CXX)
target_link_libraries(omaremote-gliff PRIVATE omaremote-link PkgConfig::AV PkgConfig::VA PkgConfig::WAYLAND
                      OpenMP::OpenMP_CXX)
target_compile_options(omaremote-gliff PRIVATE -Wall -Wextra -Wno-unused-parameter)
add_executable(gliff-proto-test gliff/test.cpp gliff/askpass.cpp gliff/clipboard.cpp gliff/seat.cpp common/link.cpp
               ${PROTOCOL_GEN}/ext-data-control-v1-protocol.c)
target_include_directories(gliff-proto-test PRIVATE ${PROTOCOL_GEN})
target_link_libraries(gliff-proto-test PRIVATE PkgConfig::WAYLAND OpenMP::OpenMP_CXX)
target_compile_options(gliff-proto-test PRIVATE -Wall -Wextra)

# The QML side: RdpView shows a session in the app and forwards input.
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick)
qt_standard_project_setup(REQUIRES 6.5)
qt_add_qml_module(omaremote_plugin
  URI OMARemote
  VERSION 1.0
  PLUGIN_TARGET omaremote_plugin
  OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/OMARemote
  SOURCES plugin/rdpview.h plugin/rdpview.cpp plugin/pasteguard.h plugin/pasteguard.cpp plugin/clipread.h plugin/clipread.cpp
          plugin/shortcutinhibit.h plugin/shortcutinhibit.cpp plugin/yuvnode.h plugin/yuvnode.cpp
)
# Gliff pictures drawn from the decoder's dmabufs (plugin/yuvnode.cpp): EGL imports them, the
# shaders convert. OpenGL scene graph only, so GLSL alone.
find_package(Qt6 REQUIRED COMPONENTS ShaderTools)
qt_add_shaders(omaremote_plugin "omaremote_shaders"
  PREFIX "/omaremote"
  BASE plugin
  GLSL "300es,150"
  BATCHABLE
  NOHLSL NOMSL
  FILES plugin/shaders/yuv.vert plugin/shaders/yuv.frag
)
pkg_check_modules(EGL REQUIRED IMPORTED_TARGET egl)
# Gliff tabs take Hyprland's shortcuts while focused: keyboard-shortcuts-inhibit, generated here.
set(INHIBIT_XML ${WAYLAND_PROTOCOLS_DIR}/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml)
set(INHIBIT_GEN ${PROTOCOL_GEN})
add_custom_command(
  OUTPUT ${INHIBIT_GEN}/keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h
         ${INHIBIT_GEN}/keyboard-shortcuts-inhibit-unstable-v1-protocol.c
  COMMAND ${CMAKE_COMMAND} -E make_directory ${INHIBIT_GEN}
  COMMAND ${WAYLAND_SCANNER} client-header ${INHIBIT_XML} ${INHIBIT_GEN}/keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h
  COMMAND ${WAYLAND_SCANNER} private-code ${INHIBIT_XML} ${INHIBIT_GEN}/keyboard-shortcuts-inhibit-unstable-v1-protocol.c
  DEPENDS ${INHIBIT_XML})
target_sources(omaremote_plugin PRIVATE ${INHIBIT_GEN}/keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h
                                        ${INHIBIT_GEN}/keyboard-shortcuts-inhibit-unstable-v1-protocol.c)
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)
target_link_libraries(omaremote_plugin PRIVATE Qt6::Quick Qt6::GuiPrivate PkgConfig::WAYLAND PkgConfig::EGL PkgConfig::VA)
target_include_directories(omaremote_plugin PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/plugin ${INHIBIT_GEN})
target_compile_options(omaremote_plugin PRIVATE -Wall -Wextra)
