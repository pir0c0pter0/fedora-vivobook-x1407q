Name:           noctalia
Version:        5.5.0
Release:        1.yoga.fc45
Summary:        A sleek, customizable desktop shell crafted for Wayland
License:        MIT AND BSD-3-Clause AND Apache-2.0
URL:            https://github.com/noctalia-dev/noctalia
%global debug_package %{nil}
%global __strip /usr/bin/llvm-strip

%description
Noctalia 5.5.0 cross-compiled for the private Yoga Fedora live image.
The release source includes its vendored dependencies.

%install
mkdir -p %{buildroot}
cp -a /work/noctalia-stage/. %{buildroot}/
llvm-strip %{buildroot}/usr/bin/noctalia
install -Dm644 /work/noctalia-release/LICENSE %{buildroot}/usr/share/licenses/noctalia/LICENSE
install -Dm644 /work/noctalia-release/CREDITS.md %{buildroot}/usr/share/licenses/noctalia/CREDITS.md

%files
/usr/bin/noctalia
/usr/share/noctalia
/usr/share/applications/dev.noctalia.Noctalia.desktop
/usr/share/applications/dev.noctalia.Noctalia.Annotator.desktop
/usr/share/icons/hicolor/scalable/apps/noctalia.svg
%license /usr/share/licenses/noctalia
