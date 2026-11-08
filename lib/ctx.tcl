namespace eval ::tuck::ctx {}

# Alias the ctx surface into a (rules) interpreter. The single `ctx` command is
# bound to an erroring stub until analysis curries a real node into it (see
# ::tuck::phase::analyse).
proc ::tuck::ctx::install {interp} {
    $interp alias ctx ::tuck::ctx::_unbound
}

# Bound to `ctx` until analysis curries a target node in; calling it means an
# impl used ctx outside an analysis invocation.
proc ::tuck::ctx::_unbound {args} {
    error "tuck: ctx: no target bound (used outside analysis)"
}

# Forward `ctx <subcmd> <args...>` to the matching accessor with the curried
# node as the first argument.
proc ::tuck::ctx::dispatch {node subcmd args} {
    switch -- $subcmd {
        attr - label - package - declare_output - action - dep_outputs - path {
            return [::tuck::ctx::$subcmd $node {*}$args]
        }
        default {
            error "tuck: ctx: unknown subcommand '$subcmd'"
        }
    }
}

# Exec path of an artifact, for building command lines.
proc ::tuck::ctx::path {ctx id} {
    return [::tuck::graph::exec_path $id]
}

proc ::tuck::ctx::label {ctx} {
    return [dict get $ctx label]
}

proc ::tuck::ctx::package {ctx} {
    return [dict get $ctx package]
}

# repo-relative path for a package-relative source path
proc ::tuck::ctx::_relpath {pkg p} {
    if {$pkg eq ""} {
        return $p
    }
    return "$pkg/$p"
}

# Type-resolved attribute access.
proc ::tuck::ctx::attr {ctx key} {
    set rule   [dict get $ctx rule]
    set schema [dict get $::tuck::graph::rules $rule schema]
    if {![dict exists $schema $key]} {
        error "tuck: ctx attr: no attribute '$key'"
    }
    set attrs [dict get $ctx attrs]
    if {![dict exists $attrs $key]} {
        return {}
    }
    set type [dict get $schema $key type]
    set val  [dict get $attrs $key]
    set pkg  [dict get $ctx package]
    switch -- $type {
        sources {
            set ids {}
            foreach p $val {
                lappend ids [::tuck::graph::register_source [::tuck::ctx::_relpath $pkg $p]]
            }
            return $ids
        }
        dep {
            return [::tuck::util::canon $val $pkg]
        }
        deps {
            set out {}
            foreach l $val {
                lappend out [::tuck::util::canon $l $pkg]
            }
            return $out
        }
        default {
            return $val
        }
    }
}

# Declare an output artifact for this target; returns its id. Published in
# target_outputs (visible to dependents via dep_outputs) unless -private.
proc ::tuck::ctx::declare_output {ctx relpath args} {
    set private 0
    foreach opt $args {
        if {$opt ne "-private"} {
            error "tuck: ctx declare_output: unknown option '$opt'"
        }
        set private 1
    }
    # Splitting on / yields an empty part for absolute paths, `a//b` and a
    # trailing slash.
    set parts [split $relpath /]
    if {$relpath eq "" || "" in $parts || "." in $parts || ".." in $parts} {
        error "tuck: ctx declare_output: invalid path '$relpath'"
    }
    set label [dict get $ctx label]
    set id [::tuck::graph::register_declared $label $relpath]
    if {!$private} {
        dict lappend ::tuck::graph::target_outputs $label $id
    }
    return $id
}

# Return the declared output ids of an already-analysed dependency.
proc ::tuck::ctx::dep_outputs {ctx label} {
    if {![dict exists $::tuck::graph::target_outputs $label]} {
        error "tuck: ctx dep_outputs: $label has no analysed outputs"
    }
    return [dict get $::tuck::graph::target_outputs $label]
}

# Register a static action node. Named args: inputs outputs cmd ?env?.
proc ::tuck::ctx::action {ctx args} {
    if {[llength $args] % 2 != 0} {
        error "tuck: ctx action: arguments must be key/value pairs"
    }
    set spec [dict create env {}]
    foreach {k v} $args {
        dict set spec $k $v
    }
    foreach req {inputs outputs cmd} {
        if {![dict exists $spec $req]} {
            error "tuck: ctx action: missing $req"
        }
    }
    return [::tuck::graph::register_action [dict get $ctx label] \
        [dict get $spec inputs] [dict get $spec outputs] \
        [dict get $spec cmd] [dict get $spec env]]
}
