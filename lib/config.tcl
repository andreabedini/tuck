namespace eval ::tuck::config {
    variable root ""
}

# Walk up from $start until a directory containing .tuck/ is found.
proc ::tuck::config::find_root {start} {
    set dir [file normalize $start]
    while 1 {
        if {[file isdirectory [file join $dir .tuck]]} {
            return $dir
        }
        set parent [file dirname $dir]
        if {$parent eq $dir} {
            error "tuck: no .tuck/ found at or above $start"
        }
        set dir $parent
    }
}

# Detect and cache the repo root.
proc ::tuck::config::init {start} {
    variable root
    set root [::tuck::config::find_root $start]
    return $root
}
