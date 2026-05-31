namespace eval ::tuck::graph {
    variable targets {}
}

# Every dep of every loaded target must name a known target.
proc ::tuck::graph::validate {} {
    variable targets
    dict for {label node} $targets {
        foreach dep [dict get $node deps] {
            if {![dict exists $targets $dep]} {
                error "tuck: $label depends on unknown target $dep"
            }
        }
    }
    return ""
}

proc ::tuck::graph::_visit {label stateVar resultVar path} {
    variable targets
    upvar 1 $stateVar state $resultVar result
    if {[dict exists $state $label]} {
        if {[dict get $state $label] eq "visiting"} {
            error "tuck: dependency cycle: [join [concat $path $label] { -> }]"
        }
        return
    }
    dict set state $label visiting
    foreach dep [dict get $targets $label deps] {
        ::tuck::graph::_visit $dep state result [concat $path $label]
    }
    dict set state $label done
    lappend result $label
}

# Post-order DFS topo sort from $seeds. Leaves first. Detects cycles.
proc ::tuck::graph::topo_sort {seeds} {
    set state {}
    set result {}
    foreach s $seeds {
        ::tuck::graph::_visit $s state result {}
    }
    return $result
}
