
package main

import "core:sync"
import "core:math"
import "core:c/libc"
import "core:mem"
import "vendor:miniaudio"


calculate_rms :: proc "contextless" (samples: []f32) -> f32 {
    sum: f32 = 0
    for sample in samples {
        sum += sample * sample
    }
    return math.sqrt(sum / f32(len(samples)))
}

// real‑time audio callback 
data_callback :: proc "c"(device: ^miniaudio.device, output: rawptr, input: rawptr, frame_count: u32) {
    if input == nil || output == nil {
        return
    }

    data      := cast(^UserData) device.pUserData
    in_buf    := cast([^]f32) input
    out_buf   := cast([^]f32) output
    frame_count_u64 := u64(frame_count)

    // level detection and latch 
    rms := calculate_rms(([^]f32)(in_buf)[0:frame_count])
    if rms > THRESHOLD {
        data.tone_countdown = TONE_HOLD_FRAMES
        _ = libc.printf("RMS: %f\n", rms)
    }

    // prepare tone(s) if active 
    
    frames_read_hi: u64
    frames_read_low: u64
    tone_hi : [BUFFER_FRAMES]f32
    tone_lo : [BUFFER_FRAMES]f32
    active := data.tone_countdown > 0


    if active {
        _ = miniaudio.waveform_read_pcm_frames(&data.wave_hi, &tone_hi[0],  frame_count_u64, &frames_read_hi)
        if AMP_LOW > 0 {
            _ = miniaudio.waveform_read_pcm_frames(&data.wave_low, &tone_lo[0],  frame_count_u64, &frames_read_low)
        }
    }

    //Mix tone into playback and adaptive‑cancel from mic --------------------
    for i in 0..<frame_count {
        tone_sample: f32 = 0.0
        if active {
            tone_sample = tone_hi[i]
            if AMP_LOW > 0 {
                tone_sample += tone_lo[i]
            }
            out_buf[i] = tone_sample
        } else {
            out_buf[i] = 0.0
        }
    
        // -------- adaptive cancellation -------------
        learn := active           // only adapt while the tone is playing
        mic_clean := nlms_step(data.nlms, tone_sample, in_buf[i], learn)
    
        in_buf[i] = mic_clean     // write the cleaned sample back
    }

    if active {
      // _ =  miniaudio.notch2_process_pcm_frames(&data.notch_filter, rawptr(in_buf), rawptr(in_buf), u64(frame_count))
        data.tone_countdown -= i32(frame_count)
        if data.tone_countdown < 0 {    
            data.tone_countdown = 0
        }
    }

    // 4. Push adjusted mic frames to ring buffer ----------------------------------
    write_buff_ptr: rawptr
    number_of_frames := u32(frame_count)
    acquire_status := miniaudio.pcm_rb_acquire_write(&data.ring_buffer, &number_of_frames, &write_buff_ptr)
    
    if acquire_status != .SUCCESS {
        when ODIN_DEBUG {
            _ = libc.printf("DEBUG: data_callback: pcm_rb_acquire_write failed. Error: %v", acquire_status)
        }
    } else { // acquire_status == .SUCCESS
        if  number_of_frames > 0 { // Check if any frames were actually acquired
            if write_buff_ptr != nil {
                // Copy the ACTUAL number of acquired frames
                mem.copy(write_buff_ptr, rawptr(in_buf), int(number_of_frames) * size_of(f32))
                
                commit_status := miniaudio.pcm_rb_commit_write(&data.ring_buffer, number_of_frames, write_buff_ptr
                ) 
                if commit_status != .SUCCESS {
                    when ODIN_DEBUG {
                        _ = libc.printf("DEBUG: pcm_rb_commit_write failed. Error:", commit_status)
                    }
                }
            } else {
                when ODIN_DEBUG {
                    _ = libc.printf(
                        "DEBUG: pcm_rb_acquire_write SUCCESS, frames_acquired > 0 (", number_of_frames, 
                        "), but actual_buffer_pointer is nil.",
                    )
                }
            }
        } else { 
            when ODIN_DEBUG {
                if frame_count > 0 { // 'frame_count' is the original input from callback
                _ = libc.printf("DEBUG: pcm_rb_acquire_write SUCCESS but 0 frames acquired. Input frames dropped:", frame_count)
                }
            }
        }
    }
}