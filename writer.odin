package main

import "core:sync"
import os2 "core:os/os2" 
import "core:time"
import "core:fmt"
import "vendor:miniaudio"

ReadError :: struct {
    message: string,
}

WriteError :: struct {
    message: string,
}

writer_thread_status :: struct {
    fatal_error: writer_thread_error,
    warnings:    [dynamic]string,
}

writer_thread_error :: union #shared_nil  {
    ^ReadError,
    ^WriteError,
}

// Wwriter thread  moves data from ring buffer to ffmpeg ----------------------
writer_thread :: proc(p: rawptr) -> rawptr {
    data := cast(^UserData) p
    read_buff_ptr: rawptr

    thread_exit_error: writer_thread_error = nil
    local_warnings: [dynamic]string
    total_bytes_written_to_ffmpeg: u64 = 0

    defer {
        sync.mutex_lock(&data.lock)
        // Report fatal error
        if thread_exit_error != nil {
            if data.writer_status.fatal_error == nil { // Capture first fatal error
                data.writer_status.fatal_error = thread_exit_error
            }
            // If a fatal error occurred in this thread, signal main to stop
            data.running = false
            sync.cond_broadcast(&data.shutdown_cond)
        }
        
        if len(local_warnings) > 0 {
            if data.writer_status.warnings == nil {
                data.writer_status.warnings = make([dynamic]string);
            }
            append(&data.writer_status.warnings, ..local_warnings[:])
        }
        sync.mutex_unlock(&data.lock)

        if thread_exit_error != nil {
            sync.cond_broadcast(&data.shutdown_cond)
        }
        delete(local_warnings)
        when ODIN_DEBUG {
            fmt.eprintf("DEBUG: writer_thread finished. Total bytes written to ffmpeg: %v\n", total_bytes_written_to_ffmpeg)
        }
    }

    read_write_loop: for {

        sync.mutex_lock(&data.lock)
        should_run := data.running
        if data.writer_status.fatal_error != nil {
            should_run = false
        }
        sync.mutex_unlock(&data.lock)

        if !should_run {
            break read_write_loop
        }
        processed_data_this_iteration := false
        
        // check how many frames are available for reading FIRST
        frames_available := miniaudio.pcm_rb_available_read(&data.ring_buffer)

        if frames_available == 0 {
            // no data immediately available, sleep and re-check data.running status.
            time.sleep(10 * time.Millisecond) 
            continue read_write_loop // Go back to check should_run
        }
        
        // number_of_frames is an in/out parameter. Desired number of frames is overwritten with frames acquired.
        number_of_frames:= u32(BUFFER_FRAMES)

        acquire_status := miniaudio.pcm_rb_acquire_read(&data.ring_buffer, &number_of_frames, &read_buff_ptr )
        // number_of_frames now holds the actual number of frames acquired.
        
        if acquire_status != .SUCCESS {
            err_val := new(ReadError)
            err_val.message = fmt.tprintf("failed to acquire ring buffer memory for read. Error: %s", acquire_status)
            thread_exit_error = err_val
            break read_write_loop
        }
        if number_of_frames > 0  {
            if read_buff_ptr != nil {
                n_bytes_to_write := int(number_of_frames) * size_of(f32)
                bytes_to_write_ptr := cast([^]u8)read_buff_ptr //cast to multi-pointer
                byte_slice_to_write := bytes_to_write_ptr[:n_bytes_to_write] // convert to slice by indexing
                bytes_written, write_os2_err := os2.write(data.ffmpeg_stdin, byte_slice_to_write)
                if write_os2_err != os2.ERROR_NONE  {
                    err_val := new(WriteError)
                    err_val.message = fmt.tprintf("ffmpeg pipe write failed (os2 error code): %v", write_os2_err)
                    thread_exit_error = err_val
                    break read_write_loop
                }
                total_bytes_written_to_ffmpeg += u64(bytes_written)
                if bytes_written < n_bytes_to_write  {
                     //if the read pointer is positioned such that the number of frames requested will require a loop, 
                    //it will be clamped to the end of the buffer. Therefore, frames given may be less than the number requested.
                    frames_consumed := u32(bytes_written / size_of(f32))
                    number_of_frames = frames_consumed
                    warn_str := fmt.tprintf("ffmpeg pipe write partial (os2). Wrote %v of %v", bytes_written, n_bytes_to_write)
                    append(&local_warnings, warn_str)
                }
                commit_status := miniaudio.pcm_rb_commit_read(
                    &data.ring_buffer,
                    number_of_frames,
                    read_buff_ptr
                )
                if commit_status != .SUCCESS {
                    err_val := new(ReadError)
                    err_val.message = fmt.tprintf("failed to commit ring buffer read. Error: %s", commit_status)
                    thread_exit_error = err_val
                    break read_write_loop
                }
                processed_data_this_iteration = true
            } else {
                err_val := new(ReadError)
                err_val.message = "ring buffer read acquired, frames > 0, but read_buff_ptr is nil"
                thread_exit_error = err_val
                break read_write_loop
            }
        }

        if !processed_data_this_iteration {
            time.sleep(10*time.Millisecond)
        }
    }
    return nil
}

writer_thread_wrapper :: proc(data_ptr: rawptr) {
    data := cast(^UserData)data_ptr   // cast the rawptr from create_and_start_with_data to the ^UserData that writer_thread expects.
    _ = writer_thread(data) //
}