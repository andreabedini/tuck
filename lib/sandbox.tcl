# The pure-Tcl directory sandbox: run one action in a fresh directory that holds
# only its declared inputs, with a cleared environment. See the M3 spec §6.
#
# Runs in the root interpreter. Changes the process-wide working directory and
# ::env for the duration of the exec; safe only because execution is
# single-threaded.

namespace eval ::tuck::sandbox {
    variable counter 0
}

# Replace the whole environment with dict $d. Unsets elements one by one:
# `array unset ::env` would remove the traces that sync ::env with the process.
proc ::tuck::sandbox::_setenv {d} {
    foreach k [array names ::env] {
        unset ::env($k)
    }
    dict for {k v} $d {
        set ::env($k) $v
    }
}

proc ::tuck::sandbox::_fail {dir keep msg} {
    if {$keep} {
        append msg "\n(sandbox kept at $dir)"
    } else {
        file delete -force $dir
    }
    error $msg
}

# Run action $id. $inputs and $outputs are exec paths relative to $execroot.
# Returns the action's combined stdout+stderr.
proc ::tuck::sandbox::run {id execroot inputs outputs cmd env} {
    variable counter
    set execroot [file normalize $execroot]
    set dir [file join $execroot tuck-out sandbox [incr counter]]
    file delete -force $dir
    file mkdir [file join $dir .home] [file join $dir .tmp]
    foreach p $inputs {
        set link [file join $dir $p]
        file mkdir [file dirname $link]
        file link -symbolic $link [file join $execroot $p]
    }
    foreach p $outputs {
        file mkdir [file dirname [file join $dir $p]]
    }

    set keep [expr {[info exists ::env(TUCK_KEEP_SANDBOX)]
                    && $::env(TUCK_KEEP_SANDBOX) eq "1"}]
    set path [expr {[info exists ::env(PATH)] ? $::env(PATH) : "/usr/bin:/bin"}]
    set clean [dict merge [dict create \
        PATH $path \
        HOME [file join $dir .home] \
        TMPDIR [file join $dir .tmp] \
        LANG C LC_ALL C TZ UTC SOURCE_DATE_EPOCH 0] $env]

    set saved [array get ::env]
    set savedpwd [pwd]
    try {
        _setenv $clean
        cd $dir
        set code [catch {exec {*}$cmd 2>@1} out opts]
    } finally {
        cd $savedpwd
        _setenv $saved
    }

    if {$code} {
        set ec [dict get $opts -errorcode]
        set status [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
        _fail $dir $keep "tuck: action $id failed (exit $status)\n$out"
    }
    foreach p $outputs {
        if {![file exists [file join $dir $p]]} {
            _fail $dir $keep "tuck: action $id did not produce $p"
        }
    }
    foreach p $outputs {
        set dst [file join $execroot $p]
        file mkdir [file dirname $dst]
        file delete -force $dst
        file rename [file join $dir $p] $dst
    }
    file delete -force $dir
    return $out
}
