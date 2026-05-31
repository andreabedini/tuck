namespace eval ::tuck::graph {
    variable artifacts {}
    variable actions {}
    variable target_outputs {}
    variable _action_counter {}
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
proc ::tuck::graph::register_action {label inputs outputs cmd env} {
    set n 0
    if {[dict exists $::tuck::graph::_action_counter $label]} {
        set n [dict get $::tuck::graph::_action_counter $label]
    }
    dict set ::tuck::graph::_action_counter $label [expr {$n + 1}]
    set id "$label#$n"
    dict set ::tuck::graph::actions $id [dict create \
        id $id target $label inputs $inputs outputs $outputs \
        cmd $cmd env $env dynamic false]
    return $id
}
