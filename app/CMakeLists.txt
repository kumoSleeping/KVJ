cmake_minimum_required(VERSION 3.22)
project(KVJ VERSION 0.3.0 LANGUAGES CXX)
if(APPLE)
    enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2 Svg ShaderTools Multimedia)
qt_standard_project_setup(REQUIRES 6.8)

# The Rust engine (../core/engine) is built by Cargo and linked as a static library.
include(FetchContent)
FetchContent_Declare(Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG v0.5.2)
FetchContent_MakeAvailable(Corrosion)
corrosion_import_crate(
    MANIFEST_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../Cargo.toml
    CRATES kvj-engine
    CRATE_TYPES staticlib)

qt_add_executable(KVJ MACOSX_BUNDLE WIN32
    src/main.cpp
)
set_source_files_properties(qml/Theme.qml qml/Live.qml qml/Switcher.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(KVJ
    URI KVJ
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Projection.qml
        qml/Overlay.qml
        qml/Theme.qml
        qml/Caption.qml
        qml/IconButton.qml
        qml/TextButton.qml
        qml/Field.qml
        qml/Select.qml
        qml/Toggle.qml
        qml/Seek.qml
        qml/Transport.qml
        qml/Assistants.qml
        qml/FollowMonitor.qml
        qml/Live.qml
        qml/Stage.qml
        qml/StatusLight.qml
        qml/Sticker.qml
        qml/StickerFrame.qml
        qml/Desk.qml
        qml/Effects.qml
        qml/Reactions.qml
        qml/Words.qml
        qml/IdList.qml
        qml/Library.qml
        qml/LibraryFolder.qml
        qml/Timeline.qml
        qml/TrackRow.qml
        qml/TrackPiece.qml
        qml/TrackPlayer.qml
        qml/FollowStrip.qml
        qml/Card.qml
        qml/Heading.qml
        qml/PopMenu.qml
        qml/PopAction.qml
        qml/TopBar.qml
        qml/About.qml
        qml/ReportDialog.qml
        qml/Switcher.qml
        qml/SourceTextures.qml
        qml/Compositor.qml
        qml/Program.qml
        qml/Composer.qml
    RESOURCES
        qml/icons/blend.svg
        qml/icons/check.svg
        qml/icons/circle-alert.svg
        qml/icons/link-2.svg
        qml/icons/chevron-down.svg
        qml/icons/chevron-right.svg
        qml/icons/crosshair.svg
        qml/icons/ear.svg
        qml/icons/ellipsis.svg
        qml/icons/camera-off.svg
        qml/icons/film.svg
        qml/icons/video-off.svg
        qml/icons/folder.svg
        qml/icons/folder-open.svg
        qml/icons/info.svg
        qml/icons/circle-arrow-up.svg
        qml/icons/moon.svg
        qml/icons/music.svg
        qml/icons/sun.svg
        qml/icons/file-plus.svg
        qml/icons/folder-plus.svg
        qml/icons/grip-vertical.svg
        qml/icons/minus.svg
        qml/icons/monitor.svg
        qml/icons/panel-left.svg
        qml/icons/image.svg
        qml/icons/message-square.svg
        qml/icons/sparkles.svg
        qml/icons/pause.svg
        qml/icons/play.svg
        qml/icons/play-from.svg
        qml/icons/plus.svg
        qml/icons/refresh.svg
        qml/icons/send.svg
        qml/icons/square.svg
        qml/icons/trash.svg
        qml/icons/volume-x.svg
        qml/icons/volume-2.svg
        qml/icons/x.svg
        qml/icons/maximize.svg
        qml/icons/lock.svg
        qml/icons/lock-open.svg
        qml/icons/zap.svg
        qml/icons/fit-contain.svg
        qml/icons/crop.svg
        qml/icons/proportions.svg
        qml/icons/spline.svg
        qml/icons/arrow-up-to-line.svg
        qml/icons/arrow-down-to-line.svg
        qml/icons/arrow-right-to-line.svg
        qml/icons/square-sharp.svg
        qml/icons/square-round.svg
        qml/icons/circle.svg
        qml/icons/polyline.svg
        qml/icons/cast.svg
        qml/icons/undo-2.svg
        qml/icons/rows-2.svg
        qml/icons/rectangle-horizontal.svg
        qml/emoji/1f389.webp
        qml/emoji/1f44f.webp
        qml/emoji/1f496.webp
        qml/emoji/1f525.webp
        qml/emoji/1f602.webp
        qml/emoji/1f62e.webp
        qml/emoji/1f64c.webp
        qml/emoji/1f973.webp
        qml/emoji/1f60d.webp
        qml/emoji/1f918.webp
        qml/emoji/2728.webp
        qml/emoji/1faa9.webp
        qml/emoji/1f40d.webp
    SOURCES
        src/Engine.h src/Engine.cpp
        src/VideoSurface.h src/VideoSurface.cpp
        src/VideoPlayer.h src/VideoPlayer.cpp
        src/PictureSource.h src/PictureSource.cpp
        src/PreviewSurface.h src/PreviewSurface.cpp
        src/CameraSurface.h src/CameraSurface.cpp
        src/Cameras.h src/Cameras.cpp
        src/FilmStrip.h src/FilmStrip.cpp
        src/WaveStrip.h src/WaveStrip.cpp
        src/FrameNode.h
        src/AudioFollower.h src/AudioFollower.cpp
        src/Decoder.h
        src/Awake.h
)
# Picture effects and the compositor's masked slot, compiled to every shading
# language Qt Quick may run on.
qt_add_shaders(KVJ "shaders"
    PREFIX "/qt/qml/KVJ"
    FILES shaders/effects.frag shaders/mask.frag)
target_include_directories(KVJ PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../core/engine/include)

# Rubber Band (../vendor/rubberband, unmodified, as KDJ vendors it): the
# picture's sound stretched to the picture's speed, pitch kept. Its official
# single-file unit, with its own resampler and FFT, or Accelerate's on Apple.
add_library(rubberband STATIC ${CMAKE_CURRENT_SOURCE_DIR}/../vendor/rubberband/single/RubberBandSingle.cpp)
target_include_directories(rubberband PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../vendor/rubberband)
target_compile_definitions(rubberband PUBLIC RUBBERBAND_STATIC PRIVATE NOMINMAX)
if(MSVC)
    target_compile_options(rubberband PRIVATE /w)
else()
    target_compile_options(rubberband PRIVATE -w)
endif()
if(APPLE)
    target_link_libraries(rubberband PUBLIC "-framework Accelerate")
endif()

target_link_libraries(KVJ PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Svg Qt6::Multimedia kvj_engine rubberband)
# System libraries the Rust static library needs, from
# `cargo rustc -p kvj-engine --crate-type staticlib -- --print native-static-libs`.
if(APPLE)
    # ScreenCaptureKit (12.3+) and the Core Audio process tap (14.2+) are used only
    # when present at run time; weak links keep KVJ launching on macOS 12.
    target_link_libraries(KVJ PRIVATE
        "-weak_framework ScreenCaptureKit" "-weak_framework CoreAudio"
        "-framework CoreMedia" "-framework AudioToolbox"
        "-framework Foundation" "-framework CoreFoundation" "-framework Security" iconv objc)
elseif(WIN32)
    target_link_libraries(KVJ PRIVATE kernel32 ntdll userenv ws2_32 dbghelp)
endif()

if(APPLE)
    target_sources(KVJ PRIVATE src/platform/mac/AvfDecoder.mm src/platform/mac/TitleBar.mm src/platform/mac/Awake.mm)
    # App icon (design/icon/make.py), copied into Contents/Resources.
    target_sources(KVJ PRIVATE resources/icon/KVJ.icns)
    set_source_files_properties(resources/icon/KVJ.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    set_source_files_properties(src/platform/mac/AvfDecoder.mm src/platform/mac/TitleBar.mm src/platform/mac/Awake.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(KVJ PRIVATE
        "-framework AVFoundation" "-framework CoreMedia" "-framework CoreVideo" "-framework Foundation" "-framework AppKit")
    set_target_properties(KVJ PROPERTIES
        OUTPUT_NAME KVJ
        MACOSX_BUNDLE_GUI_IDENTIFIER com.kumo.kvj
        MACOSX_BUNDLE_BUNDLE_NAME KVJ
        MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
        MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
        MACOSX_BUNDLE_ICON_FILE KVJ.icns
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in)
elseif(WIN32)
    # KVJ.rc carries the app icon as IDI_ICON1: Explorer shows it, and Qt uses it for windows.
    target_sources(KVJ PRIVATE src/platform/win/MfDecoder.cpp src/platform/win/TitleBar.cpp src/platform/win/Awake.cpp resources/KVJ.rc)
    target_compile_definitions(KVJ PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(KVJ PRIVATE mfplat mfreadwrite mfuuid d3d11 dxgi ole32 propsys)
endif()

# Headless decoder/player check (not shipped).
option(KVJ_BUILD_CHECKS "Build headless checks" OFF)
if(KVJ_BUILD_CHECKS)
    qt_add_executable(kvj-player-check checks/player_check.cpp src/VideoPlayer.cpp)
    target_include_directories(kvj-player-check PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(kvj-player-check PRIVATE Qt6::Core Qt6::Gui)
    set_target_properties(kvj-player-check PROPERTIES MACOSX_BUNDLE OFF WIN32_EXECUTABLE OFF)
    if(APPLE)
        target_sources(kvj-player-check PRIVATE src/platform/mac/AvfDecoder.mm)
        target_link_libraries(kvj-player-check PRIVATE
            "-framework AVFoundation" "-framework CoreMedia" "-framework CoreVideo" "-framework Foundation")
    elseif(WIN32)
        target_sources(kvj-player-check PRIVATE src/platform/win/MfDecoder.cpp)
        target_compile_definitions(kvj-player-check PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
        target_link_libraries(kvj-player-check PRIVATE mfplat mfreadwrite mfuuid d3d11 dxgi ole32 propsys)
    endif()

    qt_add_executable(kvj-sound-check checks/sound_check.cpp src/AudioFollower.cpp)
    target_include_directories(kvj-sound-check PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/../core/engine/include)
    target_link_libraries(kvj-sound-check PRIVATE Qt6::Gui Qt6::Multimedia Qt6::Qml kvj_engine rubberband)
    set_target_properties(kvj-sound-check PROPERTIES MACOSX_BUNDLE OFF WIN32_EXECUTABLE OFF)
    if(APPLE)
        target_link_libraries(kvj-sound-check PRIVATE
            "-weak_framework ScreenCaptureKit" "-weak_framework CoreAudio"
            "-framework CoreMedia" "-framework AudioToolbox"
            "-framework Foundation" "-framework CoreFoundation" "-framework Security" iconv objc)
    elseif(WIN32)
        target_link_libraries(kvj-sound-check PRIVATE kernel32 ntdll userenv ws2_32 dbghelp)
    endif()
endif()

include(GNUInstallDirs)
install(TARGETS KVJ
    BUNDLE DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
qt_generate_deploy_qml_app_script(
    TARGET KVJ
    OUTPUT_SCRIPT deploy_script
    NO_UNSUPPORTED_PLATFORM_ERROR)
install(SCRIPT ${deploy_script})
if(APPLE)
    # Drop what Qt's deployment adds but KVJ never loads, keep one architecture.
    install(CODE "execute_process(COMMAND \"${CMAKE_CURRENT_SOURCE_DIR}/packaging/trim-macos.sh\" \"\${CMAKE_INSTALL_PREFIX}/KVJ.app\" COMMAND_ERROR_IS_FATAL ANY)")
endif()
