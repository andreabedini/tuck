namespace eval ::tuck {
    variable _current_pkg ""
}
namespace eval ::tuck::graph {
    variable targets {}
}

# Collect dep labels from attrs whose schema type is dep/deps, canonicalized.
proc ::tuck::extract_deps {schema attrs pkg} {
    set deps {}
    dict for {attr def} $schema {
        if {![dict exists $attrs $attr]} continue
        switch -- [dict get $def type] {
            dep {
                lappend deps [::tuck::util::canon [dict get $attrs $attr] $pkg]
            }
            deps {
                foreach l [dict get $attrs $attr] {
                    lappend deps [::tuck::util::canon $l $pkg]
                }
            }
        }
    }
    return $deps
}

# Constructor callback: validate attrs, build node, register it.
proc ::tuck::register_target {rule attrs} {
    variable _current_pkg
    set rdef   [dict get $::tuck::graph::rules $rule]
    set schema [dict get $rdef schema]
    set valid  [::tuck::validate_attrs $rule $schema $attrs]
    set name   [dict get $valid name]
    # The name becomes a path component of the target's output directory
    # (::tuck::graph::exec_path), so it must not be able to escape it.
    if {![regexp {^[A-Za-z0-9_.+=,@~-]+$} $name] || $name in {. ..}} {
        error "tuck: invalid target name '$name' in //$_current_pkg"
    }
    set label  [::tuck::util::label_canon $_current_pkg $name]
    if {[dict exists $::tuck::graph::targets $label]} {
        error "tuck: duplicate target label: $label"
    }
    set deps [::tuck::extract_deps $schema $valid $_current_pkg]
    dict set ::tuck::graph::targets $label [dict create \
        label $label rule $rule attrs $valid package $_current_pkg deps $deps]
}
