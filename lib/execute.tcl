# The execution phase: order the actions needed for some artifacts, decide which
# are stale, and run those in the directory sandbox. See the M3 spec §5–§7.

namespace eval ::tuck::phase {
    variable _order {}
    variable _state {}
}

# Leaves-first list of the action ids needed to produce $artifact_ids.
proc ::tuck::phase::plan_actions {artifact_ids} {
    variable _order {}
    variable _state {}
    foreach aid $artifact_ids {
        _visit_artifact $aid {}
    }
    return $_order
}

proc ::tuck::phase::_visit_artifact {aid path} {
    set art [dict get $::tuck::graph::artifacts $aid]
    if {[dict get $art type] eq "source"} {
        set rel [dict get $art path]
        if {![file isfile [file join $::tuck::config::root $rel]]} {
            error "tuck: missing source file $rel"
        }
        return
    }
    if {![dict exists $::tuck::graph::producers $aid]} {
        error "tuck: no action produces $aid"
    }
    _visit_action [dict get $::tuck::graph::producers $aid] $path
}

# Post-order DFS over input -> producer edges; $path is the current DFS stack,
# used to report cycles.
proc ::tuck::phase::_visit_action {act path} {
    variable _order
    variable _state
    if {[dict exists $_state $act]} {
        if {[dict get $_state $act] eq "visiting"} {
            set cyc [lrange $path [lsearch -exact $path $act] end]
            lappend cyc $act
            error "tuck: action cycle: [join $cyc { -> }]"
        }
        return
    }
    dict set _state $act visiting
    lappend path $act
    foreach in [dict get $::tuck::graph::actions $act inputs] {
        _visit_artifact $in $path
    }
    dict set _state $act done
    lappend _order $act
}
