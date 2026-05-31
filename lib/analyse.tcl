namespace eval ::tuck::phase {}

# Analyse the closure of $labels, leaves-first, invoking each target's compiled
# rule impl to populate the action graph.
proc ::tuck::phase::analyse {labels} {
    set canon {}
    foreach l $labels {
        lappend canon [::tuck::util::canon $l ""]
    }
    set pkgs {}
    foreach c $canon {
        lappend pkgs [dict get [::tuck::util::label_parse $c] pkg]
    }
    ::tuck::phase::load_closure $pkgs
    ::tuck::graph::validate
    foreach label [::tuck::graph::topo_sort $canon] {
        set node [dict get $::tuck::graph::targets $label]
        set rule [dict get $node rule]
        set impl [dict get $::tuck::graph::rules $rule impl]
        if {$impl eq ""} {
            error "tuck: rule $rule has no impl"
        }
        $::tuck::interp::rules eval [list $impl $node]
    }
}
