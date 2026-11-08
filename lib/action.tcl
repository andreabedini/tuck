namespace eval ::tuck::graph {
    variable artifacts {}
    variable actions {}
    variable target_outputs {}
    variable _action_counter {}
    variable producers {}
}

proc ::tuck::graph::source_id {relpath} {
    return "source:$relpath"
}

proc ::tuck::graph::declared_id {label relpath} {
    return "declared:$label:$relpath"
}

# Register a source artifact (idempotent). Returns its id.
proc ::tuck::graph::register_source {relpath} {
    set id [::tuck::graph::source_id $relpath]
    dict set ::tuck::graph::artifacts $id [dict create type source path $relpath]
    return $id
}

# Register a declared artifact (idempotent). Returns its id.
proc ::tuck::graph::register_declared {label relpath} {
    set id [::tuck::graph::declared_id $label $relpath]
    dict set ::tuck::graph::artifacts $id \
        [dict create type declared target $label relpath $relpath]
    return $id
}

# Register a static action node for $label. Returns the generated id.
# Errors if any output already has a producing action.
proc ::tuck::graph::register_action {label inputs outputs cmd env} {
    set n 0
    if {[dict exists $::tuck::graph::_action_counter $label]} {
        set n [dict get $::tuck::graph::_action_counter $label]
    }
    set id "$label#$n"
    foreach o $outputs {
        if {[dict exists $::tuck::graph::producers $o]} {
            error "tuck: $o is produced by both [dict get $::tuck::graph::producers $o] and $id"
        }
    }
    dict set ::tuck::graph::_action_counter $label [expr {$n + 1}]
    dict set ::tuck::graph::actions $id [dict create \
        id $id target $label inputs $inputs outputs $outputs \
        cmd $cmd env $env dynamic false]
    foreach o $outputs {
        dict set ::tuck::graph::producers $o $id
    }
    return $id
}

# Path of an artifact relative to the exec root (the repo root, or a sandbox).
# Pure string function: no I/O, safe to expose to rule impls via `ctx path`.
proc ::tuck::graph::exec_path {id} {
    if {![dict exists $::tuck::graph::artifacts $id]} {
        error "tuck: unknown artifact '$id'"
    }
    set a [dict get $::tuck::graph::artifacts $id]
    if {[dict get $a type] eq "source"} {
        return [dict get $a path]
    }
    regexp {^//(.*):([^:]+)$} [dict get $a target] -> pkg name
    set base [expr {$pkg eq "" ? "tuck-out" : "tuck-out/$pkg"}]
    return "$base/__${name}__/[dict get $a relpath]"
}
