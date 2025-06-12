//------------------------------------------------------------------------------
// Microphone monitor / live MP3 recorder – Odin implementation
//------------------------------------------------------------------------------
//  * Captures microphone input (48 kHz, f32)
//  * Detects when the RMS level exceeds THRESHOLD and, while active, plays a
//    tone to the speakers.
//  * Raw microphone data (without the tone) is pushed through a pcm‑aware ring
//    buffer and streamed to `ffmpeg` for on‑the‑fly MP3 encoding.
//------------------------------------------------------------------------------
package main

import "core:fmt"
import "core:flags"
import os2 "core:os/os2" 
import "core:sync"
import "core:time"
import "core:strings"
import "core:thread"
import "core:c/libc"
import "vendor:miniaudio"


when ODIN_OS == .Linux {
    @require foreign import "system:dl"      // libdl.so  
    @require foreign import "system:pthread" // libpthread.so
    @require foreign import "system:m"       // libm.so    
}



//------------------------------------------------------------------------------
// Parameters

SAMPLE_RATE     :: 48_000
CHANNELS        :: 1
THRESHOLD       :: 0.1

// Primary tone
FREQ_HIGH       :: 1_000.0
AMP_HIGH        :: 0.2
// Sub‑tone (set AMP_LOW=0 to disable)
FREQ_LOW        :: 20.0
AMP_LOW         :: 0.1

TONE_HOLD_FRAMES:: SAMPLE_RATE          // 1 s latch

RINGBUF_FRAMES  :: SAMPLE_RATE * 10     // 10 s rolling buffer
BUFFER_FRAMES   :: 1_024                // must be ≥ device callback size

//cli flags
CliArgs :: struct {
    input_device  : string `usage:"microphone device"`,
    output_device : string `usage:"output sound device"`,
    ffmpeg_path: string `usage:"ffmpeg path to executable"`,
    list_devices: bool `usage:"list available capture and playback devices"`,
}


// data passed to the audio callback
_global_user_data_ptr: ^UserData // Global pointer for signal handler access

UserData :: struct {
    tone_countdown : i32,                      // frames left to emit tone
    wave_hi        : miniaudio.waveform,       
    wave_low       : miniaudio.waveform,       
    ring_buffer    : miniaudio.pcm_rb,
    notch_filter   : miniaudio.notch2,
    nlms           : ^NLMS_Filter, 
    ffmpeg_stdin   : ^os2.File, 
    ffmpeg_process : os2.Process,
    running        : bool,
    lock           : sync.Mutex,
    shutdown_cond  : sync.Cond,
    writer_status  : writer_thread_status,
   }


// helpers
is_running :: proc(d: ^UserData) -> bool {
    sync.mutex_lock(&d.lock)
    result := d.running
    sync.mutex_unlock(&d.lock)
    return result
}


sigint_handler :: proc "c" (sig: i32) {
    if _global_user_data_ptr != nil {
        sync.mutex_lock(&_global_user_data_ptr.lock)
        // check if already shutting down to prevent multiple signals causing issues.
        if _global_user_data_ptr.running {
            _global_user_data_ptr.running = false
            // signal the main thread to wake up from cond_wait.
            sync.cond_broadcast(&_global_user_data_ptr.shutdown_cond)
        }
        sync.mutex_unlock(&_global_user_data_ptr.lock)
    }
}
    
//------------------------------------------------------------------------------
// Entry point
//------------------------------------------------------------------------------
main :: proc() {

    //parse cli flags
    args := CliArgs{
		ffmpeg_path = "ffmpeg",
	}

    style : flags.Parsing_Style = .Odin
    flags.parse_or_exit(&args, os2.args, style)

    //print available devices on request

    devices : Devices
    if args.list_devices {
        devices = enumerate_devices()
        print_devices(devices)
        return
    }

    //init user data
    data : UserData
    _global_user_data_ptr = &data

    // PCM ring buffer initialisation (internally allocates heap) -------------
    rb_init_status := miniaudio.pcm_rb_init(miniaudio.format.f32, CHANNELS, RINGBUF_FRAMES,
                             nil, nil, &data.ring_buffer)
    if rb_init_status != .SUCCESS {
        fmt.eprintln("Failed to initialise PCM ring buffer",  rb_init_status)
        return
    }
    defer miniaudio.pcm_rb_uninit(&data.ring_buffer)

    //waveform initialization
    waveform_config_high := miniaudio.waveform_config_init(miniaudio.format.f32, CHANNELS, SAMPLE_RATE, 
        miniaudio.waveform_type.sine, AMP_HIGH, FREQ_HIGH)
    waveform_config_low := miniaudio.waveform_config_init(miniaudio.format.f32, CHANNELS, SAMPLE_RATE,
        miniaudio.waveform_type.sine, AMP_LOW, FREQ_LOW)
    
    if miniaudio.waveform_init(&waveform_config_high, &data.wave_hi) != .SUCCESS {
        fmt.eprintln("Failed to initialise waveform high")
        return
    }
    if miniaudio.waveform_init(&waveform_config_low, &data.wave_low) != .SUCCESS {
        fmt.eprintln("Failed to initialise waveform low")
        return
    }

    defer {
        miniaudio.waveform_uninit(&data.wave_hi)
        miniaudio.waveform_uninit(&data.wave_low)
    }

    //filter init

    notch_config := miniaudio.notch2_config_init(miniaudio.format.f32, CHANNELS, SAMPLE_RATE, 15, FREQ_HIGH)
    if miniaudio.notch2_init(&notch_config, nil, &data.notch_filter) != .SUCCESS {
        fmt.eprintln("Failed to initialise notch filter")
        return
    }

    data.nlms = nlms_init(256, 0.6) 

    defer  miniaudio.notch2_uninit(&data.notch_filter, nil)
    
    // spawn ffmpeg 
    ffmpeg_args := []string{
        args.ffmpeg_path,
        "-y",
        "-f", "f32le",
        "-ar", "48000",
        "-ac", "1",
        "-i", "-",
        "-acodec", "libmp3lame",
        "output.mp3",
    }
    ffmpeg_cmd_str := "/mnt/c/Users/amcwi/ffmpeg/bin/ffmpeg.exe -y -f f32le -ar 48000 -ac 1 -i - -acodec libmp3lame output.mp3"

    
    // Create a pipe for ffmpeg's stdin
    stdin_read_end, stdin_write_end, pipe_err := os2.pipe()
    if pipe_err != nil { 
        fmt.eprintln("Failed to create os2.pipe for ffmpeg stdin:", pipe_err)
        return
    }
    data.ffmpeg_stdin = stdin_write_end // We write to this end

    proc_desc := os2.Process_Desc {
        command     = ffmpeg_args,
        stdin       = stdin_read_end, // ffmpeg's stdin is the read end of pipe
        stdout      = os2.stdout,     // to the console
        stderr      = os2.stderr,     // to the console
        working_dir = "",             // Empty means inherit current working directory
        env         = nil,            // nil means inherit current environment
    }
    // start  ffmpeg process
    process_handle, start_err := os2.process_start(proc_desc)
    if start_err != nil { 
        fmt.eprintln("Failed to start ffmpeg with os2.process_start:", start_err)
        // Use os2.close()
        _ = os2.close(stdin_read_end) 
        _ = os2.close(stdin_write_end) 
        data.ffmpeg_stdin = nil 
        return
    }
    data.ffmpeg_process = process_handle

     // after successfully starting ffmpeg, the parent process MUST close
    // its copy of the pipe end that the child (ffmpeg) is now using for its stdin.
    close_err_read_end := os2.close(stdin_read_end)
    if close_err_read_end != nil {
        fmt.eprintln("Warning: Failed to close stdin_read_end after ffmpeg start:", close_err_read_end)
        // potentially make fatal
    }

    defer {
        // Close the write-end of the pipe (^os2.File) that the parent was using.
        if data.ffmpeg_stdin != nil {
            close_err_write_end := os2.close(data.ffmpeg_stdin)
            if close_err_write_end != nil {
                 fmt.eprintln("Warning: Failed to close ffmpeg_stdin (write end) on exit:", close_err_write_end)
            }
        }

        if data.ffmpeg_process.handle != 0 { 
            exit_code_obj, wait_err := os2.process_wait(data.ffmpeg_process) 
            if wait_err != nil { 
                fmt.eprintln("Error waiting for ffmpeg process:", wait_err)
            } else if exit_code_obj.exited && exit_code_obj.exit_code != 0 {
                fmt.eprintln("ffmpeg process exited with code:", exit_code_obj.exit_code)
            } else if !exit_code_obj.exited {
                 fmt.eprintln("ffmpeg process did not exit cleanly (wait returned but not exited).")
            }
            
            // Close the process handle itself 
            close_err_proc := os2.process_close(data.ffmpeg_process)
            if close_err_proc != nil { 
                fmt.eprintln("Warning: Failed to close ffmpeg process handle:", close_err_proc)
            }
        }
    }

    // Register SIGINT handler (signal returns a pointer to the previous handler)
    old_sigint_handler := libc.signal(libc.SIGINT, sigint_handler)
    fmt.println("DEBUG: libc.signal returned ptr =", old_sigint_handler);

    //transmute old_sigint_handler to rawptr for a meaningful comparison.
    if cast(rawptr)old_sigint_handler == libc.SIG_ERR {
        fmt.eprintln("Warning: Failed to set SIGINT handler using libc.signal. Ctrl+C shutdown may not be available.")
    } else {
        // defer restoring the actual previous handler.
        defer libc.signal(libc.SIGINT, old_sigint_handler)
    }

    // background writer thread 
    sync.mutex_lock(&data.lock)
    data.running = true
    data.writer_status.warnings = make([dynamic]string)
    sync.mutex_unlock(&data.lock)
    t : ^thread.Thread 
    t = thread.create_and_start_with_data(&data, writer_thread_wrapper) 
 
    // configure duplex device
    cfg := miniaudio.device_config_init(miniaudio.device_type.duplex)
    cfg.capture.format    = miniaudio.format.f32 
    cfg.capture.channels  = CHANNELS
    cfg.playback.format   = miniaudio.format.f32 
    cfg.playback.channels = CHANNELS
    cfg.sampleRate       = SAMPLE_RATE
    cfg.dataCallback     = data_callback
    cfg.pUserData        = &data

    devices = enumerate_devices()

    if args.input_device != "" {
        input_devid_id, found := get_device_id(devices.playback, args.input_device)
        if !found {
            fmt.eprintln("Input device not found:", args.input_device)
            return
        }
        cfg.capture.pDeviceID = input_devid_id
    }

    if args.output_device != "" {
        output_devid_id, found := get_device_id(devices.capture, args.output_device)
        if !found {
            fmt.eprintln("Output device not found:", args.input_device)
            return
        }
        cfg.playback.pDeviceID = output_devid_id
    }

    //init miniaudio device
    device : miniaudio.device
    device_init_status := miniaudio.device_init(nil, &cfg, &device)

    if device_init_status != .SUCCESS {
        fmt.eprintln("Failed to open audio device.", miniaudio.result_description(device_init_status))
        // signal the writer thread to stop.
        sync.mutex_lock(&data.lock)
        data.running = false
        sync.cond_broadcast(&data.shutdown_cond)
        sync.mutex_unlock(&data.lock)
    } 

    defer miniaudio.device_uninit(&device)
    device_start_status := miniaudio.device_start(&device)
    if device_start_status != .SUCCESS {
        fmt.eprintln("Failed to start audio device.", miniaudio.result_description(device_start_status))
        sync.mutex_lock(&data.lock)
        data.running = false
        sync.cond_broadcast(&data.shutdown_cond)
        sync.mutex_unlock(&data.lock)
    } else {
         fmt.println("Monitoring: press Ctrl+C to stop …")
    }
    

    //  wait for shutdown signal (data.running to become false)
    sync.mutex_lock(&data.lock) // Acquire lock before checking/waiting
    for data.running { 
        // sync.cond_wait atomically releases the lock, re-acquires the lock on signal before returning.
        sync.cond_wait(&data.shutdown_cond, &data.lock)
    }
    sync.mutex_unlock(&data.lock) // Release lock 

    fmt.println("Shutting down audio processing...")
   
    // wait for the writer thread to finish defer block.
    if t != nil { 
        thread.join(t)
    }

    sync.mutex_lock(&data.lock)
    final_writer_status := data.writer_status 
    sync.mutex_unlock(&data.lock)

    when ODIN_DEBUG {
        if len(final_writer_status.warnings) > 0 {
            fmt.eprintln("-------------------------------------------------")
            fmt.eprintln("Messages/Warnings from writer thread:")
            for warn_msg, i in final_writer_status.warnings {
                fmt.eprintf("  [%d] %s\n", i, warn_msg) // 
            }
            fmt.eprintln("-------------------------------------------------")
        }
   }

    // process fatal errors.
    if final_writer_status.fatal_error != nil {
        fmt.eprintln("-------------------------------------------------")
        fmt.eprintln("FATAL ERROR from writer thread:")
        // type switch  
        switch err_val in final_writer_status.fatal_error{
        case ^ReadError:
            fmt.eprintf("  Read Error: %s\n", err_val.message)
            free(err_val)
        case ^WriteError:
            fmt.eprintf("  Write Error: %s\n", err_val.message)
           free(err_val)
        }
        fmt.eprintln("-------------------------------------------------")
    }
    
    fmt.println("FFmpeg processing and audio capture stopped. File will be at output.mp3 (if successful).")
}

