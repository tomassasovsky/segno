# vst3/CMakeLists.txt — Segno.vst3: Segno's built-in effects as VST3
# plugins for a DAW on the dev Mac (#1804), one class per effect kind
# (segno_fx_kinds.h), each running the engine's effects island.
#
# Built and installed on the Mac by install.sh; not signed, not shipped,
# not part of the engine's code asset (src/CMakeLists.txt). It also builds
# on Linux, where CI runs the null test so a change to the engine cannot
# leave the plugins behind. The vendored VST3 SDK carries no CMake helpers,
# so the bundle is assembled by hand below.
cmake_minimum_required(VERSION 3.18)
if(APPLE)
  project(segno_vst3 LANGUAGES C CXX OBJCXX)
else()
  project(segno_vst3 LANGUAGES C CXX)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

get_filename_component(ENGINE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../src" ABSOLUTE)
get_filename_component(VST3_SDK
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vst3sdk" ABSOLUTE)

# The SDK's fdebug.h needs one of its own DEVELOPMENT / RELEASE defines.
add_compile_definitions(
  "$<$<CONFIG:Debug>:DEVELOPMENT=1>"
  "$<$<NOT:$<CONFIG:Debug>>:RELEASE=1>")

# --- the effects island ------------------------------------------------------
# engine_fx.c and what it links against, as bench_fx_equiv.sh builds it. It
# renders with the console's tanhf and powf (fx_console_libm.h), so on this
# Mac a plugin computes what the console's engine computes; macOS's own
# differ by an ulp here and there, which the drives' filters turn into a
# residual near -90 dBFS. -fmath-errno keeps Clang from fusing a sinf and a
# cosf into Apple's sincos, as on Linux.
add_library(segno_fx_island STATIC
  fx_slot.c
  "${ENGINE_SRC}/core/engine_fx.c"
  "${ENGINE_SRC}/core/rt_alloc.c"
  "${ENGINE_SRC}/core/plugin_disabled.c")
set_target_properties(segno_fx_island PROPERTIES
  C_STANDARD 11 C_EXTENSIONS ON POSITION_INDEPENDENT_CODE ON)
target_include_directories(segno_fx_island PUBLIC
  "${ENGINE_SRC}/core" "${ENGINE_SRC}/midi" "${ENGINE_SRC}/miniaudio"
  "${ENGINE_SRC}/host")
target_compile_options(segno_fx_island PRIVATE
  -fmath-errno
  -include "${ENGINE_SRC}/test/bench/fx_console_libm.h")

# --- the SDK's plugin side ---------------------------------------------------
add_library(segno_vst3_sdk STATIC
  "${VST3_SDK}/base/source/fobject.cpp"
  "${VST3_SDK}/base/source/fstring.cpp"
  "${VST3_SDK}/base/source/fdebug.cpp"
  "${VST3_SDK}/base/source/updatehandler.cpp"
  "${VST3_SDK}/base/source/baseiids.cpp"
  "${VST3_SDK}/base/thread/source/flock.cpp"
  "${VST3_SDK}/pluginterfaces/base/coreiids.cpp"
  "${VST3_SDK}/pluginterfaces/base/funknown.cpp"
  "${VST3_SDK}/pluginterfaces/base/ustring.cpp"
  "${VST3_SDK}/public.sdk/source/common/commoniids.cpp"
  "${VST3_SDK}/public.sdk/source/common/pluginview.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vstinitiids.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vstcomponent.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vstcomponentbase.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vstaudioeffect.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vstbus.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vsteditcontroller.cpp"
  "${VST3_SDK}/public.sdk/source/vst/vstparameters.cpp"
  "${VST3_SDK}/public.sdk/source/main/pluginfactory.cpp")
set_target_properties(segno_vst3_sdk PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(segno_vst3_sdk PUBLIC "${VST3_SDK}")
if(APPLE)
  set(SEGNO_MODULE_ENTRY "${VST3_SDK}/public.sdk/source/main/macmain.cpp")
  target_link_libraries(segno_vst3_sdk PUBLIC "-framework CoreFoundation")
else()
  set(SEGNO_MODULE_ENTRY "${VST3_SDK}/public.sdk/source/main/linuxmain.cpp")
  # pluginfactory.cpp's Linux timer hook lives in timer.cpp.
  find_package(Threads REQUIRED)
  target_sources(segno_vst3_sdk PRIVATE "${VST3_SDK}/base/source/timer.cpp")
  target_link_libraries(segno_vst3_sdk PUBLIC Threads::Threads ${CMAKE_DL_LIBS})
endif()

# --- Segno.vst3 --------------------------------------------------------------
# The module entry (bundleEntry / ModuleEntry) is compiled into the module
# itself: nothing references it, so from a static library the linker would
# drop it.
add_library(segno_vst3 MODULE
  "${SEGNO_MODULE_ENTRY}"
  factory.cpp
  processor.cpp
  controller.cpp
  value_text.cpp)
target_link_libraries(segno_vst3 PRIVATE segno_vst3_sdk segno_fx_island)
if(APPLE)
  # The pedal-face editor (editor.h); elsewhere a host shows its own
  # controls.
  target_sources(segno_vst3 PRIVATE editor_mac.mm)
  set_source_files_properties(editor_mac.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  # Names the editor's Objective-C class for this build, so two copies of
  # the bundle in one host process do not share it.
  string(RANDOM LENGTH 12 ALPHABET "0123456789abcdef" SEGNO_VST3_BUILD_ID)
  target_compile_definitions(segno_vst3 PRIVATE
    "SEGNO_VST3_BUILD_ID=${SEGNO_VST3_BUILD_ID}")
  target_link_libraries(segno_vst3 PRIVATE "-framework Cocoa")
endif()
set_target_properties(segno_vst3 PROPERTIES
  OUTPUT_NAME Segno PREFIX "" SUFFIX ""
  C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden)

set(SEGNO_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/Segno.vst3")
if(APPLE)
  target_link_options(segno_vst3 PRIVATE
    -exported_symbols_list "${VST3_SDK}/public.sdk/source/main/macexport.exp")
  add_custom_command(TARGET segno_vst3 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${SEGNO_BUNDLE}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${SEGNO_BUNDLE}/Contents/MacOS"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:segno_vst3>"
      "${SEGNO_BUNDLE}/Contents/MacOS/Segno"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
      "${SEGNO_BUNDLE}/Contents/Info.plist"
    COMMAND /bin/sh -c "printf 'BNDL????' > '${SEGNO_BUNDLE}/Contents/PkgInfo'"
    # Ad hoc: a local build for this Mac, never distributed.
    COMMAND codesign -f -s - "${SEGNO_BUNDLE}"
    COMMENT "Assembling Segno.vst3"
    VERBATIM)
  # The editors' pictures and layout (editor.h), rendered by install.sh into
  # SEGNO_VST3_FACES. Copied on every build, since the pictures change
  # without the module relinking, and signed again after.
  set(SEGNO_VST3_FACES "" CACHE PATH
    "Rendered pedal faces for the editors (install.sh renders them)")
  if(SEGNO_VST3_FACES)
    add_custom_target(segno_vst3_faces ALL
      COMMAND ${CMAKE_COMMAND} -E rm -rf "${SEGNO_BUNDLE}/Contents/Resources/faces"
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${SEGNO_VST3_FACES}"
        "${SEGNO_BUNDLE}/Contents/Resources/faces"
      COMMAND codesign -f -s - "${SEGNO_BUNDLE}"
      COMMENT "Bundling the pedal faces"
      VERBATIM)
    add_dependencies(segno_vst3_faces segno_vst3)
  endif()
else()
  # Segno.vst3/Contents/<machine>-linux/Segno.so, the VST3 bundle layout.
  set(SEGNO_ARCH "${CMAKE_SYSTEM_PROCESSOR}-linux")
  set_target_properties(segno_vst3 PROPERTIES SUFFIX ".so")
  add_custom_command(TARGET segno_vst3 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${SEGNO_BUNDLE}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${SEGNO_BUNDLE}/Contents/${SEGNO_ARCH}"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:segno_vst3>"
      "${SEGNO_BUNDLE}/Contents/${SEGNO_ARCH}/Segno.so"
    COMMENT "Assembling Segno.vst3"
    VERBATIM)
endif()

# --- the null test (test/null_test.cpp) --------------------------------------
# Loads the built bundle as a host does and renders every kind through it
# and through the engine's offline render (perf_render.c, from the engine's
# own library, built here with the console's tanhf and powf as the island
# is), then reports the residual.
add_subdirectory("${ENGINE_SRC}" engine EXCLUDE_FROM_ALL)
set_source_files_properties("${ENGINE_SRC}/core/engine_fx.c"
  TARGET_DIRECTORY segno_engine
  PROPERTIES COMPILE_OPTIONS
    "-fmath-errno;-include;${ENGINE_SRC}/test/bench/fx_console_libm.h")
# What a test needs to load the bundle as a host does.
add_library(segno_vst3_host STATIC
  "${VST3_SDK}/public.sdk/source/vst/hosting/module.cpp"
  "${VST3_SDK}/public.sdk/source/vst/hosting/hostclasses.cpp"
  "${VST3_SDK}/public.sdk/source/vst/hosting/parameterchanges.cpp"
  "${VST3_SDK}/public.sdk/source/vst/hosting/pluginterfacesupport.cpp"
  "${VST3_SDK}/public.sdk/source/vst/hosting/processdata.cpp"
  "${VST3_SDK}/public.sdk/source/vst/utility/stringconvert.cpp"
  "${VST3_SDK}/public.sdk/source/common/commonstringconvert.cpp"
  "${VST3_SDK}/public.sdk/source/common/memorystream.cpp")
target_link_libraries(segno_vst3_host PUBLIC segno_vst3_sdk)
if(APPLE)
  target_sources(segno_vst3_host PRIVATE
    "${VST3_SDK}/public.sdk/source/vst/hosting/module_mac.mm")
  set_source_files_properties(
    "${VST3_SDK}/public.sdk/source/vst/hosting/module_mac.mm"
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_libraries(segno_vst3_host PUBLIC "-framework Foundation")
else()
  target_sources(segno_vst3_host PRIVATE
    "${VST3_SDK}/public.sdk/source/vst/hosting/module_linux.cpp")
endif()

add_executable(segno_vst3_null_test test/null_test.cpp test/capture_log.c)
target_link_libraries(segno_vst3_null_test PRIVATE segno_vst3_host segno_fx_island
  segno_engine)
add_dependencies(segno_vst3_null_test segno_vst3)

# --- the binding test (test/binding_test.cpp) ---------------------------------
# Every control of the editors' layout (faces/faces.json) drives a parameter
# its plugin's controller lists.
add_executable(segno_vst3_binding_test
  test/binding_test.cpp
  "${ENGINE_SRC}/core/json_read.c")
target_include_directories(segno_vst3_binding_test PRIVATE "${ENGINE_SRC}/core")
target_link_libraries(segno_vst3_binding_test PRIVATE segno_vst3_host)
add_dependencies(segno_vst3_binding_test segno_vst3)
