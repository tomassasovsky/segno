cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "sub_window_plugin_registrant.cc"
  "task_runner_timeout_guard.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE ${CMAKE_DL_LIBS})

# task_runner_timeout_guard.cc replaces g_timeout_add for the Flutter embedder
# (#1299). The interposition only works if the executable exports the symbol;
# the linker would also export it because libflutter_linux_gtk.so references
# it, but that is incidental, so say it explicitly.
target_link_options(${BINARY_NAME} PRIVATE
  "LINKER:--export-dynamic-symbol=g_timeout_add")

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
