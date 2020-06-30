# Tarballinator 9000

A tool to create a tarball containing a specific RPM package and its dependencies,
optionally cutting off some of the dependencies: either based on what's already
installed on a system (`libsolv` cache file) or on a list of packages specified
manually.
