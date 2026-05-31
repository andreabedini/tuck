namespace eval ::tuck::util {}

proc ::tuck::util::_basename {pkg} {
    if {$pkg eq ""} {
        error "tuck: malformed label: // needs an explicit :name"
    }
    return [lindex [split $pkg /] end]
}

# Parse a label into {pkg <p> name <n>}. Relative ":name" uses $current_pkg.
proc ::tuck::util::label_parse {label {current_pkg ""}} {
    if {[string range $label 0 1] eq "//"} {
        set rest [string range $label 2 end]
        set cidx [string first : $rest]
        if {$cidx < 0} {
            set pkg $rest
            set name [::tuck::util::_basename $pkg]
        } else {
            set pkg  [string range $rest 0 [expr {$cidx - 1}]]
            set name [string range $rest [expr {$cidx + 1}] end]
        }
    } elseif {[string index $label 0] eq ":"} {
        set pkg $current_pkg
        set name [string range $label 1 end]
    } else {
        error "tuck: malformed label: $label"
    }
    if {$name eq ""} {
        error "tuck: malformed label: empty target name in $label"
    }
    return [dict create pkg $pkg name $name]
}

proc ::tuck::util::label_canon {pkg name} {
    return "//$pkg:$name"
}

# Canonicalize an arbitrary (possibly relative) label against $pkg.
proc ::tuck::util::canon {label pkg} {
    set p [::tuck::util::label_parse $label $pkg]
    return [::tuck::util::label_canon [dict get $p pkg] [dict get $p name]]
}
