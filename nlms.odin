package main 

NLMS_Filter :: struct {
    len     : int,     // number of taps
    mu      : f32,     // adaptation rate   (0.1–1.0 typical)
    eps_inv : f32,     
    w       : []f32,   // weights   [len]
    x       : []f32,   // delay line[len]
}

nlms_init :: proc(len: int, mu: f32 = 0.5, eps: f32 = 1e-6) -> ^NLMS_Filter {
    f := new(NLMS_Filter)
    f.len     = len
    f.mu      = mu
    f.eps_inv = 1.0 / eps
    f.w       = make([]f32, len)
    f.x       = make([]f32, len)
    return f
}

// Process one sample 
// returns the error signal  (mic − estimated_tone). If `learn = true`, run the NLMS update,
// otherwise return the prediction without adjusting weights.
nlms_step :: proc "contextless" (f: ^NLMS_Filter, ref, mic: f32, learn: bool) -> f32 {
    // shift delay line
    for i := f.len-1; i > 0; i -= 1 {
        f.x[i] = f.x[i-1]
    }
    f.x[0] = ref

    // y = Σ w·x  (estimate of tone at mic)
    y: f32 = 0.0
    for i in 0..<f.len {
        y += f.w[i] * f.x[i]
    }

    e := mic - y // error (mic minus estimate). The clean sample.

    if learn {
        norm: f32 = 0.0
        for i in 0..<f.len {
            norm += f.x[i] * f.x[i]
        }
        g := f.mu * e / (norm + 1e-8)
        for i in 0..<f.len {
            f.w[i] += g * f.x[i]
        }
    }
    return e
}