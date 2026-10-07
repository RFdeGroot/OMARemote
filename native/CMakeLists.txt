cmake_minimum_required(VERSION 3.21)
project(omaremote-native LANGUAGES CXX)

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

add_executable(omaremote-rdp rdp/main.cpp)
target_link_libraries(omaremote-rdp PRIVATE omaremote-link PkgConfig::FREERDP)
target_compile_options(omaremote-rdp PRIVATE -Wall -Wextra -Wno-unused-parameter)

# VNC sessions, on libvncclient.
pkg_check_modules(VNC REQUIRED IMPORTED_TARGET libvncclient)
add_executable(omaremote-vnc vnc/main.cpp)
target_link_libraries(omaremote-vnc PRIVATE omaremote-link PkgConfig::VNC)
target_compile_options(omaremote-vnc PRIVATE -Wall -Wextra -Wno-unused-parameter)

# The QML side: RdpView shows a session in the app and forwards input.
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick)
qt_standard_project_setup(REQUIRES 6.5)
qt_add_qml_module(omaremote_plugin
  URI OMARemote
  VERSION 1.0
  PLUGIN_TARGET omaremote_plugin
  OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/OMARemote
  SOURCES plugin/rdpview.h plugin/rdpview.cpp
)
target_link_libraries(omaremote_plugin PRIVATE Qt6::Quick)
target_include_directories(omaremote_plugin PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/plugin)
target_compile_options(omaremote_plugin PRIVATE -Wall -Wextra)
