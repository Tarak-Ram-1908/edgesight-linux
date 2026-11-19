cmake_minimum_required(VERSION 3.16)
project(edgesightd VERSION 1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(WITH_ORT    "ONNX Runtime backend"    ON)
option(WITH_TFLITE "TensorFlow Lite backend" ON)
set(ORT_ROOT "" CACHE PATH "Optional ONNX Runtime install prefix (native builds)")

find_package(Threads REQUIRED)
find_package(JPEG REQUIRED)
find_path(MOSQUITTO_INCLUDE_DIR mosquitto.h REQUIRED)
find_library(MOSQUITTO_LIBRARY mosquitto REQUIRED)
find_path(SECCOMP_INCLUDE_DIR seccomp.h REQUIRED)
find_library(SECCOMP_LIBRARY seccomp REQUIRED)

add_executable(edgesightd
  src/main.cpp
  src/common.cpp
  src/image.cpp
  src/source.cpp
  src/http.cpp
  src/mqtt.cpp
  src/sandbox.cpp
  src/stats.cpp)

target_include_directories(edgesightd PRIVATE ${MOSQUITTO_INCLUDE_DIR} ${SECCOMP_INCLUDE_DIR})
target_link_libraries(edgesightd PRIVATE Threads::Threads JPEG::JPEG ${MOSQUITTO_LIBRARY} ${SECCOMP_LIBRARY})
target_compile_options(edgesightd PRIVATE -Wall -Wextra -Wno-unused-parameter)

if(WITH_ORT)
  find_path(ORT_INCLUDE_DIR onnxruntime_cxx_api.h
            HINTS ${ORT_ROOT}/include PATH_SUFFIXES onnxruntime REQUIRED)
  find_library(ORT_LIBRARY onnxruntime HINTS ${ORT_ROOT}/lib REQUIRED)
  target_sources(edgesightd PRIVATE src/engine_ort.cpp)
  target_include_directories(edgesightd PRIVATE ${ORT_INCLUDE_DIR})
  target_link_libraries(edgesightd PRIVATE ${ORT_LIBRARY})
  target_compile_definitions(edgesightd PRIVATE HAVE_ORT=1)
endif()

if(WITH_TFLITE)
  find_path(TFLITE_INCLUDE_DIR tensorflow/lite/interpreter.h REQUIRED)
  find_library(TFLITE_LIBRARY tensorflow-lite REQUIRED)
  target_sources(edgesightd PRIVATE src/engine_tflite.cpp)
  target_include_directories(edgesightd PRIVATE ${TFLITE_INCLUDE_DIR})
  target_link_libraries(edgesightd PRIVATE ${TFLITE_LIBRARY})
  target_compile_definitions(edgesightd PRIVATE HAVE_TFLITE=1)
endif()

install(TARGETS edgesightd RUNTIME DESTINATION bin)
