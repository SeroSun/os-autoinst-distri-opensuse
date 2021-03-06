# SUSE's openQA tests
#
# Copyright © 2009-2013 Bernhard M. Wiedemann
# Copyright © 2012-2017 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Package: eog
# Summary: eye of gnome image viewer
# - Installs eog if necessary
# - Launch eog
# - Check if eog is running
# - Close eog
# Maintainer: QE Core <qe-core@suse.de>

use base "x11test";
use strict;
use warnings;
use testapi;
use utils;


sub run {
    assert_gui_app('eog', exec_param => get_var('WALLPAPER'));
}

1;
