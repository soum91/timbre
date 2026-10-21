Timbre 0.3.1 Dopamine install registration patch

Upload all files inside Tweak/ to the same paths on the timbre-rootless branch,
replacing Tweak/control and Tweak/TimbreControl/Info.plist, and adding
Tweak/layout/DEBIAN/postinst and Tweak/layout/DEBIAN/prerm.

The existing GitHub Actions rootless DEB workflow will build and publish a
new .deb. Verify the new package contains the maintainer scripts and that
Timbre appears after installing/upgrading in Sileo.

This does NOT establish system-wide audio DSP functionality. Device testing
is still needed, and rootless audio hooks can destabilize audio services.
