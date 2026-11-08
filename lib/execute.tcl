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

proc ::tuck::phase::_db_path {} {
    return [file join $::tuck::config::root tuck-out .db]
}

proc ::tuck::phase::_db_load {} {
    set p [_db_path]
    if {![file exists $p]} {
        return {}
    }
    set f [open $p r]
    set d [read $f]
    close $f
    if {[catch {dict size $d}]} {
        return {}   ;# corrupt database: treat everything as stale
    }
    return $d
}

proc ::tuck::phase::_db_save {db} {
    set p [_db_path]
    file mkdir [file dirname $p]
    set f [open $p.tmp w]
    puts -nonewline $f $db
    close $f
    file rename -force $p.tmp $p
}

proc ::tuck::phase::_paths {ids} {
    return [lmap id $ids {::tuck::graph::exec_path $id}]
}

# What, besides its inputs, determines an action's outputs.
proc ::tuck::phase::_key {a} {
    return [list [dict get $a cmd] [dict get $a env]]
}

# exec path -> {mtime size} for each input.
proc ::tuck::phase::_stamps {a} {
    set s {}
    foreach p [_paths [dict get $a inputs]] {
        set f [file join $::tuck::config::root $p]
        dict set s $p [list [file mtime $f] [file size $f]]
    }
    return $s
}

proc ::tuck::phase::_stale {db a} {
    foreach p [_paths [dict get $a outputs]] {
        if {![file exists [file join $::tuck::config::root $p]]} {
            return 1
        }
    }
    set id [dict get $a id]
    if {![dict exists $db $id]} {
        return 1
    }
    set rec [dict get $db $id]
    return [expr {[dict get $rec key] ne [_key $a]
                  || [dict get $rec inputs] ne [_stamps $a]}]
}

proc ::tuck::phase::_report {report args} {
    if {$report ne ""} {
        {*}$report {*}$args
    }
}

# Materialize $artifact_ids. $report, if given, is a command prefix called as
# `{*}$report run|skip <action-id>` and `{*}$report output <action-id> <text>`.
# Returns the list of {run|skip <action-id>} events.
proc ::tuck::phase::execute {artifact_ids {report {}}} {
    set db [_db_load]
    set rebuilt {}
    set events {}
    foreach act [plan_actions $artifact_ids] {
        set a [dict get $::tuck::graph::actions $act]
        set dirty [_stale $db $a]
        # An input rebuilt in this run always makes us stale, even if the new
        # file has the same size and mtime second as the recorded one.
        foreach in [dict get $a inputs] {
            if {[dict exists $::tuck::graph::producers $in]
                && [dict get $::tuck::graph::producers $in] in $rebuilt} {
                set dirty 1
            }
        }
        if {!$dirty} {
            lappend events [list skip $act]
            _report $report skip $act
            continue
        }
        lappend events [list run $act]
        _report $report run $act
        set out [::tuck::sandbox::run $act $::tuck::config::root \
            [_paths [dict get $a inputs]] [_paths [dict get $a outputs]] \
            [dict get $a cmd] [dict get $a env]]
        if {$out ne ""} {
            _report $report output $act $out
        }
        lappend rebuilt $act
        dict set db $act [dict create key [_key $a] inputs [_stamps $a]]
        _db_save $db
    }
    return $events
}
