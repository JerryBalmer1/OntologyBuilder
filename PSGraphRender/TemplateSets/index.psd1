@{
    # Which backend renders when a caller names none.
    #
    # This is the whole reason the file exists. Changing which backend is
    # default must be a data edit, and the name of one backend must not appear
    # in a .ps1 anywhere - the moment it does, the reference implementation is
    # privileged in code and "a template set is a rendering backend" stops being
    # true.
    #
    # There is deliberately no list of backends here. Discovery is enumerating
    # directories beside this file that contain a templateset.psd1, so adding a
    # backend is adding a directory and nothing else. A list would be a second
    # place to forget.
    Default = 'cytoscape'
}
