package main

import "core:fmt"
import "vendor:miniaudio"
import "core:strings"

//list audio interfaces

DevicesInfo :: struct {
    device_info: [^]miniaudio.device_info,
    device_count: u32,
}

Devices :: struct {
    playback: DevicesInfo,
    capture: DevicesInfo,
}

enumerate_devices :: proc() -> Devices  {

    ma_context : miniaudio.context_type
    if miniaudio.context_init(nil, 0, nil, &ma_context) != .SUCCESS {
        fmt.eprintln("Failed to initialise miniaudio context")
    }
    defer miniaudio.context_uninit(&ma_context)

    devices : Devices  

    if miniaudio.context_get_devices(&ma_context, &devices.playback.device_info, &devices.playback.device_count, &devices.capture.device_info, &devices.capture.device_count) != .SUCCESS {
        fmt.eprintln("Failed to enumerate audio devices")
    }
    return devices
}

print_devices :: proc(devices: Devices ) {
    fmt.println("-------------------------------------------------")
    fmt.println("Playback devices:")
    for i in 0..<devices.playback.device_count {
        fmt.printf("%d - %s\n", i,  devices.playback.device_info[i].name)
    }
    fmt.println("\nCapture devices:")
    for i in 0..<devices.capture.device_count {
        fmt.printf("%d - %s\n", i,  devices.capture.device_info[i].name)
    }
    fmt.println("-------------------------------------------------")
}

get_device_id :: proc(infos: DevicesInfo, name: string) -> (^miniaudio.device_id, bool) {

    if name == "" {
        return nil, false
    }
    for i in 0..<infos.device_count {
        device_name := string(cstring(&infos.device_info[i].name[0]))
        if device_name == name {
            return &infos.device_info[i].id, true
        }
    }
    return nil, false
}

