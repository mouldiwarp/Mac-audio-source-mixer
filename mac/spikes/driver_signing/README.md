# Driver signing spike (2026-11-06)

Question: does coreaudiod load an ad-hoc-signed AudioServerPlugIn on this Mac (macOS 26.6.2, arm64)?

Answer: **yes.** "Mixer Test Mic" (2 input channels, 48 kHz, transport Virtual) appeared in `system_profiler SPAudioDataType`. No Apple Developer account is needed for local use.

## Findings
- Third-party HAL drivers run in their own process, "Core Audio Driver (<name>.driver)". They do not run inside coreaudiod, so `vmmap coreaudiod` will not show them.
- First build: the device was not published because the HAL asked for a property the driver did not support (`'who?'` from GetPropertyDataSize). The fix was adding `kAudioObjectPropertyCustomPropertyInfoList` (empty) and the other plug-in/device properties in `VirtualMixerTest.c`.
- The HAL still tries `SetPropertyData` and gets `'unop'`, because the driver makes nothing settable. Harmless here. The real driver must accept sample-rate and buffer-size changes.
- In zsh, `log` is a shell builtin. Use `/usr/bin/log show ...`.
- Driver log: `/usr/bin/log show --last 10m --info --predicate 'subsystem == "local.spike.virtualmixertest"'`

## Build
    clang -bundle -fvisibility=hidden -o VirtualMixerTest.driver/Contents/MacOS/VirtualMixerTest VirtualMixerTest.c -framework CoreAudio -framework CoreFoundation
    codesign --force --sign - VirtualMixerTest.driver

## Install / remove (sudo)
    sudo cp -R VirtualMixerTest.driver /Library/Audio/Plug-Ins/HAL/ && sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VirtualMixerTest.driver && sudo killall coreaudiod
    sudo rm -rf /Library/Audio/Plug-Ins/HAL/VirtualMixerTest.driver && sudo killall coreaudiod
