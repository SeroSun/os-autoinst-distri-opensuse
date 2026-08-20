# SUSE's openQA tests
#
# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Package: parted
# Summary: Create partitions for xfstests
# - Create a gpt partition table on device
# - Partition device according to system variable XFSTESTS_DEVICE or
# calculated home size
# Maintainer: Yong Sun <yosun@suse.com>
package partition;

use 5.018;
use Mojo::Base 'opensusebasetest';
use utils;
use testapi;
use serial_terminal 'select_serial_terminal';
use filesystem_utils qw(str_to_mb parted_print partition_num_by_type mountpoint_to_partition
  partition_table create_partition remove_partition format_partition get_partition_size);
use File::Basename;
use lockapi;
use mmapi;
use mm_network;
use nfs_common;
use Utils::Systemd 'disable_and_stop_service';
use registration;
use version_utils qw(is_transactional is_sle_micro is_sle);
use Utils::Architectures 'is_ppc64le';
use transactional;
use Kernel::block_dev qw(create_loop_backing_file attach_loop_device);
use List::Util 'sum';
use rdma;

my $INST_DIR = '/opt/xfstests';
my $CONFIG_FILE = "$INST_DIR/local.config";
my $NFS_VERSION = get_var('XFSTESTS_NFS_VERSION', '4.1');
my $NFS_SERVER_IP;
my $TEST_FOLDER = '/opt/test';
my $SCRATCH_FOLDER = '/opt/scratch';

# Number of SCRATCH disk in SCRATCH_DEV_POOL, other than btrfs has only 1 SCRATCH_DEV, xfstests specific
sub partition_amount_by_homesize {
    my $home_size = shift;
    $home_size = str_to_mb($home_size);
    my %ret;
    if ($home_size && check_var('XFSTESTS', 'btrfs')) {
        # If enough space, then have 5 disks in SCRATCH_DEV_POOL, or have 2 disks in SCRATCH_DEV_POOL
        # At least 8 GB in each SCRATCH_DEV (SCRATCH_DEV_POOL only available for btrfs tests)
        if ($home_size >= 49152) {
            $ret{num} = 5;
            $ret{size} = 1024 * int($home_size / (($ret{num} + 1) * 1024));
            return %ret;
        }
        else {
            $ret{num} = 2;
            $ret{size} = 1024 * int($home_size / (($ret{num} + 1) * 1024));
            return %ret;
        }
    }
    elsif ($home_size) {
        $ret{num} = 1;
        $ret{size} = int($home_size / 2);
        return %ret;
    }
    else {
        print "Info: Current HDD file don't have a /home partition.";
    }
    return %ret;
}

# Do partition by giving inputs
# Inputs explain
# $filesystem: filesystem type
# $amount: Amount of partitions to be created for SCRATCH_DEV. Available for btrfs, at most 5.
# $size: Size of each partition size for TEST_DEV and SCRATCH_DEV. Default: 5120
# $dev: Optional. Device to be partitioned. Default: same device as root partition
# $delhome: Delete home partition to get free space for test partition.
sub do_partition_for_xfstests {
    my $ref = shift;
    my %para = %{$ref};
    my ($part_table, $part_type, $test_dev);
    unless ($para{size}) {
        $para{size} = 5120;
    }
    unless ($para{amount}) {
        $para{amount} = 1;
    }
    if ($para{fstype} =~ /btrfs/ && $para{amount} > 5) {
        $para{amount} = 5;
    }
    else {
        # Mandatory xfs and ext4 has only 1 SCRATCH_DEV
        $para{amount} = 1;
    }
    unless (exists($para{dev})) {
        my $part = mountpoint_to_partition('/');
        if ($part =~ /(.*?)(\d+)/) {
            $para{dev} = $1;
        }
    }
    if (exists($para{delhome}) && $para{delhome} != 0) {
        my $part = mountpoint_to_partition('/home');
        remove_partition($part);
        script_run("sed -i -e '/ \/home /d' /etc/fstab");
        script_run('mkdir /home/fsgqa; mkdir /home/fsgqa-123456');
    }
    parted_print(dev => $para{dev});
    # Prepare suitable partition type, if don't have extended then create one
    $part_table = partition_table($para{dev});
    if ($part_table =~ 'msdos') {
        $part_type = 'logical';
    }
    else {
        $part_type = 'primary';
    }
    if ($part_table =~ 'msdos' && partition_num_by_type($para{dev}, 'extended') == -1) {
        create_partition($para{dev}, 'extended', 'max');
        parted_print(dev => $para{dev});
    }
    # Create TEST_DEV
    $test_dev = create_partition($para{dev}, $part_type, $para{size});
    parted_print(dev => $para{dev});
    format_with_options($test_dev, $para{fstype});
    # Create SCRATCH_DEV or SCRATCH_DEV_POOL
    my @scratch_dev;
    my $num = $para{amount};
    while ($num != 0) {
        $num -= 1;
        my $part = create_partition($para{dev}, $part_type, $para{size});
        format_partition($part, $para{fstype});
        push @scratch_dev, $part;
    }
    parted_print(dev => $para{dev});
    # Create mount points
    script_run("mkdir $TEST_FOLDER $SCRATCH_FOLDER");
    # Setup configure file xfstests/local.config
    script_run("echo 'export FSTYP=$para{fstype}' >> $CONFIG_FILE") if ($para{fstype} !~ /overlay/);
    script_run("echo 'export TEST_DEV=$test_dev' >> $CONFIG_FILE");
    set_var('XFSTESTS_TEST_DEV', $test_dev);
    script_run("echo 'export TEST_DIR=$TEST_FOLDER' >> $CONFIG_FILE");
    script_run("echo 'export SCRATCH_MNT=$SCRATCH_FOLDER' >> $CONFIG_FILE");
    if ($para{amount} == 1) {
        script_run("echo 'export SCRATCH_DEV=$scratch_dev[0]' >> $CONFIG_FILE");
        set_var('XFSTESTS_SCRATCH_DEV', $scratch_dev[0]);
    }
    else {
        my $SCRATCH_DEV_POOL = join(' ', @scratch_dev);
        script_run("echo 'export SCRATCH_DEV_POOL=\"$SCRATCH_DEV_POOL\"' >> $CONFIG_FILE");
        set_var('XFSTESTS_SCRATCH_DEV_POOL', $SCRATCH_DEV_POOL);
    }
    # Create SCRATCH_LOGDEV with disk partition
    if (get_var('XFSTESTS_LOGDEV')) {
        my $logdev = create_partition($para{dev}, $part_type, 1024);
        format_partition($logdev, $para{fstype});
        script_run("echo export SCRATCH_LOGDEV=$logdev >> $CONFIG_FILE");
        script_run("echo export USE_EXTERNAL=yes >> $CONFIG_FILE");
    }
    # Sync
    script_run('sync');
    return ($para{size} . 'M') x ($para{amount} + 1);
}

# Create loop device by giving inputs
# only available when enable XFSTESTS_LOOP_DEVICE in openQA
# Inputs explain
# $filesystem: filesystem type
# $size: Size of free space of the rootfs. The size of each TEST_DEV or SCRATCH_DEV is split 90% of $size equally.
sub create_loop_device_by_rootsize {
    my $ref = shift;
    my %para = %{$ref};
    my $amount = 1;
    my ($size, @loop_dev_size, @filename);
    if ($para{fstype} =~ /btrfs/) {
        $amount = 5;
    }
    # Use 90% of free space, not use all space in /root
    $size = int($para{size} * 0.9);
    # get device size from XFSTESTS_PART_SIZE, other devices share the rest
    if (my @part_list = split(/,/, get_var('XFSTESTS_PART_SIZE'))) {
        my $list_remaining = $amount + 1 - (scalar @part_list);
        if ($list_remaining > 0) { push(@part_list, (int(($size - (sum @part_list)) / $list_remaining)) x $list_remaining); }
        foreach (0 .. $amount) { push(@loop_dev_size, shift(@part_list) . 'M'); }
    }
    else {
        $size > (20480 * ($amount + 1)) ? ($size = 20480) : ($size = int($size / ($amount + 1)));
        foreach (0 .. $amount) { push(@loop_dev_size, $size . 'M'); }
    }
    @filename = ('test_dev');
    foreach (1 .. $amount) { push(@filename, "scratch_dev$_"); }

    my $i = 0;
    foreach (@filename) {
        create_loop_backing_file("$INST_DIR/$_", $loop_dev_size[$i]);
        attach_loop_device("$INST_DIR/$_");
        $i++;
    }
    script_run("losetup -a");
    if ($para{fstype} =~ /overlay/) {
        my $ovl_base_fs = get_var('XFSTESTS_OVERLAY_BASE_FS', 'xfs');
        format_with_options("$INST_DIR/test_dev", $ovl_base_fs);
        format_with_options("$INST_DIR/scratch_dev1", $ovl_base_fs);
        script_run("echo 'export FSTYP=$ovl_base_fs' >> $CONFIG_FILE");
    }
    else {
        format_with_options("$INST_DIR/test_dev", $para{fstype});
    }
    # Create mount points
    script_run("mkdir $TEST_FOLDER $SCRATCH_FOLDER");
    # Setup configure file xfstests/local.config
    script_run("echo 'export FSTYP=$para{fstype}' >> $CONFIG_FILE") if ($para{fstype} !~ /overlay/);
    script_run("echo 'export TEST_DEV=/dev/loop0' >> $CONFIG_FILE");
    set_var('XFSTESTS_TEST_DEV', '/dev/loop0');
    script_run("echo 'export TEST_DIR=$TEST_FOLDER' >> $CONFIG_FILE");
    script_run("echo 'export SCRATCH_MNT=$SCRATCH_FOLDER' >> $CONFIG_FILE");
    script_run("echo 'export DUMP_CORRUPT_FS=1' >> $CONFIG_FILE");
    script_run("echo 'export DUMP_COMPRESSOR=gzip' >> $CONFIG_FILE") if (script_run('which gzip') == 0);
    if ($amount == 1) {
        script_run("echo 'export SCRATCH_DEV=/dev/loop1' >> $CONFIG_FILE");
        set_var('XFSTESTS_SCRATCH_DEV', '/dev/loop1');
    }
    else {
        script_run("echo 'export SCRATCH_DEV_POOL=\"/dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5\"' >> $CONFIG_FILE");
        set_var('XFSTESTS_SCRATCH_DEV_POOL', '/dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5');
    }
    # Create SCRATCH_LOGDEV with loop device
    if (get_var('XFSTESTS_LOGDEV')) {
        my $logdev = "/dev/loop100";
        my $logdev_name = "logdev";

        create_loop_backing_file("$INST_DIR/$logdev_name", '1G');
        attach_loop_device("$INST_DIR/$logdev_name", loop_dev => $logdev);
        format_partition("$INST_DIR/$logdev_name", $para{fstype});
        script_run("echo export SCRATCH_LOGDEV=$logdev >> $CONFIG_FILE");
        script_run("echo export USE_EXTERNAL=yes >> $CONFIG_FILE");
    }
    # Sync
    script_run('sync');
    return @loop_dev_size;
}

# Create zoned device when enable XFSTESTS_ZONE_DEVICE in openQA
sub create_zoned_device {
    my @zone_dev_size;
    my $ZONE_CREATER = '/opt/nullblk-zoned.sh';

    # Get nullblk-zone.sh
    assert_script_run("curl -o $ZONE_CREATER " . data_url('xfstests/nullblk-zoned.sh'));
    assert_script_run("chmod a+x $ZONE_CREATER");

    script_run("for i in {1..6}; do $ZONE_CREATER 4096 256 4 16; done");
    assert_script_run("mkfs.btrfs -f /dev/nullb0");
    set_var('XFSTESTS_TEST_DEV', '/dev/nullb0');
    set_var('XFSTESTS_SCRATCH_DEV_POOL', '/dev/nullb1 /dev/nullb2 /dev/nullb3 /dev/nullb4 /dev/nullb5');
    script_run("mkdir $TEST_FOLDER $SCRATCH_FOLDER");
    script_run("echo 'export TEST_DEV=/dev/nullb0' >> $CONFIG_FILE");
    script_run("echo 'export TEST_DIR=$TEST_FOLDER' >> $CONFIG_FILE");
    script_run("echo 'export SCRATCH_MNT=$SCRATCH_FOLDER' >> $CONFIG_FILE");
    script_run("echo 'export DUMP_CORRUPT_FS=1' >> $CONFIG_FILE");
    script_run("echo 'export DUMP_COMPRESSOR=gzip' >> $CONFIG_FILE") if (script_run('which gzip') == 0);
    script_run("echo 'export SCRATCH_DEV_POOL=\"/dev/nullb1 /dev/nullb2 /dev/nullb3 /dev/nullb4 /dev/nullb5\"' >> $CONFIG_FILE");
    foreach (0 .. 5) { push(@zone_dev_size, '5120M'); }
    return @zone_dev_size;
}

sub set_config {
    script_run("echo export KEEP_DMESG=yes >> $CONFIG_FILE");
    if (get_var('XFSTESTS_XFS_REPAIR')) {
        script_run("echo export TEST_XFS_REPAIR_REBUILD=1 >> $CONFIG_FILE");
    }
    if (check_var('XFSTESTS', 'nfs')) {
        script_run("echo export TEST_DEV=$NFS_SERVER_IP:/opt/export/test >> $CONFIG_FILE");
        script_run("echo export TEST_DIR=/opt/nfs/test >> $CONFIG_FILE");
        script_run("echo export SCRATCH_DEV=$NFS_SERVER_IP:/opt/export/scratch >> $CONFIG_FILE");
        script_run("echo export SCRATCH_MNT=/opt/nfs/scratch >> $CONFIG_FILE");
        script_run("echo export FSTYP=nfs >> $CONFIG_FILE");
        if ($NFS_VERSION =~ 'pnfs') {
            script_run("echo export NFS_MOUNT_OPTIONS='\"-o rw,relatime,vers=4.1,minorversion=1\"' >> $CONFIG_FILE");
        }
        elsif ($NFS_VERSION =~ 'TLS') {
            script_run('modprobe tls');
            my ($vers_num) = $NFS_VERSION =~ /-([\d.]+)/;
            script_run("echo export NFS_MOUNT_OPTIONS='\"-o rw,relatime,vers=$vers_num,sec=sys,xprtsec=mtls\"' >> $CONFIG_FILE");
        }
        elsif ($NFS_VERSION =~ 'krb5') {
            my ($vers_num) = $NFS_VERSION =~ /-([\d.]+)/;
            my ($krb5_type) = $NFS_VERSION =~ /(krb5[pi]?)/;
            script_run("echo export NFS_MOUNT_OPTIONS='\"-o rw,relatime,vers=$vers_num,sec=$krb5_type\"' >> $CONFIG_FILE");
        }
        else {
            script_run("echo export NFS_MOUNT_OPTIONS='\"-o rw,relatime,vers=$NFS_VERSION\"' >> $CONFIG_FILE");
        }
    }
    record_info('Config file', script_output("cat $CONFIG_FILE"));
}

sub post_env_info {
    my @size = @_;
    # record version info
    my $ver_log = get_var('VERSION_LOG', '/opt/version.log');
    record_info('Version', script_output("cat $ver_log"));
    record_info('Kernel config', script_output('cat /boot/config-$(uname -r)'));

    # record partition size info
    my $size_info = get_var('XFSTESTS_TEST_DEV') . "    " . shift(@size) . "\n";
    if (my $scratch_dev = get_var("XFSTESTS_SCRATCH_DEV")) {
        $size_info = $size_info . "$scratch_dev    " . shift(@size) . "\n";
    }
    else {
        my @scratch_dev_pool = split(/ /, get_var("XFSTESTS_SCRATCH_DEV_POOL"));
        foreach (@scratch_dev_pool) {
            $size_info = $size_info . "$_    " . shift(@size) . "\n";
        }
    }
    $size_info = $size_info . "PAGE_SIZE     " . script_output("getconf PAGE_SIZE") . "\n";
    $size_info = $size_info . "QEMURAM       " . get_var("QEMURAM") . "\n";
    $size_info = $size_info . "\n" . script_output("df -h");
    record_info('Size', $size_info);

    # record mounted filesystem info
    my $mount_info = script_output("mount");
    record_info('Mount', $mount_info);
}

sub format_with_options {
    my ($part, $filesystem) = @_;
    # In case to test different mkfs.xfs options
    if ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'reflink_1024') != -1) {
        format_partition($part, $filesystem, options => '-f -m reflink=1,rmapbt=1, -i sparse=1, -b size=1024');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m reflink=1,rmapbt=1, -i sparse=1, -b size=1024\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'reflink_normapbt') != -1) {
        format_partition($part, $filesystem, options => '-f -m reflink=1,rmapbt=0, -i sparse=1');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m reflink=1,rmapbt=0, -i sparse=1\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'reflink') != -1) {
        format_partition($part, $filesystem, options => '-f -m reflink=1,rmapbt=1, -i sparse=1');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m reflink=1,rmapbt=1, -i sparse=1\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'nocrc_512') != -1) {
        format_partition($part, $filesystem, options => '-f -m crc=0,reflink=0,rmapbt=0, -i sparse=0, -b size=512');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m crc=0,reflink=0,rmapbt=0, -i sparse=0, -b size=512\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'nocrc') != -1) {
        format_partition($part, $filesystem, options => '-f -m crc=0,reflink=0,rmapbt=0, -i sparse=0');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m crc=0,reflink=0,rmapbt=0, -i sparse=0\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'logdev') != -1) {
        format_partition($part, 'xfs', options => '-f -m crc=1,reflink=0,rmapbt=0, -i sparse=0 -lsize=100m');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m crc=1,reflink=0,rmapbt=0, -i sparse=0 -lsize=100m\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'xfs' && index(get_required_var('TEST'), 'bigtime') != -1) {
        format_partition($part, 'xfs', options => '-f -m bigtime=1');
        script_run("echo 'export XFS_MKFS_OPTIONS=\"-m bigtime=1\"' >> $CONFIG_FILE");
    }
    # In case to test different mkfs.btrfs options
    # $XFSTEST_MKFS_OPTION: options for mkfs.btrfs
    # Example of 4k block size: -f -s 4k -n 16k
    elsif ($filesystem eq 'btrfs' && (my $mkfs_option = get_var('XFSTEST_MKFS_OPTION'))) {
        format_partition($part, 'btrfs', options => "$mkfs_option");
        script_run("echo 'export BTRFS_MKFS_OPTIONS=\"$mkfs_option\"' >> $CONFIG_FILE");
    }
    elsif ($filesystem eq 'ocfs2') {
        format_partition($part, 'ocfs2', options => '--fs-features=local --fs-feature-level=max-features');
        script_run("echo 'export MKFS_OPTIONS=\"--fs-features=local --fs-feature-level=max-features\"' >> $CONFIG_FILE");
    }
    else {
        format_partition($part, $filesystem);
    }
}

sub install_dependencies_ocfs2 {
    my $scc_product = get_var('VERSION') =~ s/-SP/./r;
    my $scc_arch = get_var('ARCH');
    my $scc_regcode = get_var('SCC_REGCODE_HA');
    add_suseconnect_product('sle-ha', $scc_product, $scc_arch, "-r $scc_regcode");
    my @deps = qw(
      ocfs2-tools
    );
    script_run('zypper --gpg-auto-import-keys ref');
    if (is_transactional) {
        trup_install(join(' ', @deps));
        reboot_on_changes;
    }
    else {
        zypper_call('in ' . join(' ', @deps));
    }
    script_run('modprobe ocfs2');
}

sub install_dependencies_nfs {
    my @deps = qw(
      nfs-kernel-server
      nfs4-acl-tools
    );
    push @deps, 'ktls-utils', 'openssl-3' if ($NFS_VERSION =~ 'TLS');
    push @deps, 'krb5-client', 'krb5-server' if ($NFS_VERSION =~ 'krb5');
    script_run('zypper --gpg-auto-import-keys ref');
    if (is_transactional) {
        trup_install(join(' ', @deps));
        reboot_on_changes;
    }
    else {
        zypper_call('in nfs-client ' . join(' ', @deps));
    }
}

sub install_dependencies_overlayfs {
    my @deps = qw(
      overlayfs-tools
      unionmount-testsuite
      libcap-progs
    );
    script_run('zypper --gpg-auto-import-keys ref');
    if (is_transactional) {
        # Excluding libcap-progs since install issue
        trup_install(join(' ', @deps[0 .. $#deps - 1]));
        reboot_on_changes;
    }
    else {
        zypper_call('in ' . join(' ', @deps));
    }
}

# --------------------------------------------------------------------------
# TEMPORARY DEBUG CODE - branch yosun/debug-tls, DO NOT MERGE
#
# Collects everything needed to file the "NFS over TLS fails while SELinux is
# enforcing" bug without having to hand-copy output out of a VNC console.
# Everything lands in a single /tmp/tls-debug.tar.xz that can be attached to
# Bugzilla as is, and the important parts are additionally shown as record_info
# so they can be selected and pasted from the openQA job page.
#
# This must not be merged: it installs extra packages, flips SELinux between
# enforcing and permissive and performs a mount A/B test, none of which belong
# in a production run.
# --------------------------------------------------------------------------
my $TLS_DEBUG_DIR = '/tmp/tls-debug';

# ausearch comes from the audit package, audit2allow from policycoreutils; the
# package holding audit2allow was renamed across products, so try both names.
sub tls_debug_install_tools {
    script_run('zypper -n --gpg-auto-import-keys in audit policycoreutils policycoreutils-python-utils'
          . ' || zypper -n in audit policycoreutils python3-policycoreutils', timeout => 900);
    script_run('systemctl start auditd');
    # The first run found no AVC at all even though setenforce clearly changes
    # the outcome, which means the denial is covered by a dontaudit rule.
    # Rebuild the policy with dontaudit disabled so it gets logged; restored in
    # tls_debug_upload.
    script_run('semodule -DB', timeout => 600);
}

sub tls_debug_dump {
    my ($stage) = @_;
    my $dir = "$TLS_DEBUG_DIR/$stage";
    script_run("mkdir -p $dir");

    # Ordered so the tarball reads top to bottom like the bug report itself.
    my @collect = (
        ['selinux.log', 'sestatus; echo ===; cat /etc/selinux/config; echo ===; cat /proc/cmdline'
              . '; echo ===; semodule -l | grep -i tls; echo ===; ps -eZ | grep tlshd'
              . '; echo ===; matchpathcon /usr/sbin/tlshd; echo ===; ls -Z /usr/sbin/tlshd'],
        ['versions.log', 'rpm -q --qf "%{NAME}-%{VERSION}-%{RELEASE} built:%{BUILDTIME:date}\n"'
              . ' selinux-policy selinux-policy-targeted ktls-utils nfs-kernel-server nfs-client'
              . ' gnutls kernel-default; echo ===; uname -a; echo ===; rpm -q --changelog selinux-policy | head -n 80'],
        ['tlshd.log', 'systemctl status tlshd --no-pager -l; echo ===; journalctl -u tlshd -b --no-pager'],
        ['avc.log', 'auditctl -s; echo ===; ls -l /var/log/audit/; echo ===; semodule -l | wc -l'
              . '; echo === journal; journalctl -k -b --no-pager | grep -i "avc:"'
              . '; echo === dmesg; dmesg | grep -i "avc:"'
              . '; echo === ausearch-all; ausearch -m AVC,USER_AVC,SELINUX_ERR -ts boot'],
        # No -c filter: the first attempt used -c tlshd and found nothing, the
        # denial may well be attributed to another comm.
        ['audit2allow.te', 'ausearch -m AVC,USER_AVC -ts boot | audit2allow -R'
              . '; echo "=== tlshd only ==="; ausearch -m AVC,USER_AVC -ts boot -c tlshd | audit2allow -R'],
        ['certs.log', 'ls -l --time-style=full-iso /etc/tlshd/'
              . '; echo ===; openssl x509 -in /etc/tlshd/ca.pem -noout -dates -subject'
              . '; echo ===; openssl x509 -in /etc/tlshd/server.pem -noout -dates -subject -ext subjectAltName'
              . '; echo ===; openssl x509 -in /etc/tlshd/client.pem -noout -dates -subject -ext subjectAltName'
              . '; echo ===; openssl verify -CAfile /etc/tlshd/ca.pem /etc/tlshd/server.pem /etc/tlshd/client.pem'],
        ['nfs.log', 'cat /etc/tlshd.conf; echo ===; cat /etc/exports; echo ===; exportfs -v'
              . '; echo ===; cat /opt/xfstests/local.config; echo ===; nfsstat -m; echo ===; mount | grep nfs'],
    );

    for my $item (@collect) {
        my ($file, $cmd) = @$item;
        script_run("{ $cmd ; } > $dir/$file 2>&1", timeout => 300);
        # Only a tail goes to record_info, the full file is in the tarball. The
        # tr strips control characters that would upset the serial console.
        record_info("tls-debug $stage: $file", script_output(
                "tail -n 150 $dir/$file | tr -cd '\\11\\12\\15\\40-\\176'",
                proceed_on_failure => 1, timeout => 180));
    }
}

# The AVC only shows up once a handshake has actually been attempted, so drive
# the mount both ways. Bounded with timeout(1) because a rejected handshake
# makes mount(8) sit there for minutes.
sub tls_debug_mount_ab {
    my ($vers) = @_;
    my $probe = "umount /opt/nfs/test 2>/dev/null; echo \"== mode: \$(getenforce)\"; "
      . "timeout 180 mount -t nfs -o rw,relatime,vers=$vers,sec=sys,xprtsec=mtls 127.0.0.1:/opt/export/test /opt/nfs/test; "
      . "echo \"== mount rc=\$?\"; mount | grep /opt/nfs/test; umount /opt/nfs/test 2>/dev/null";

    script_run('setenforce 1');
    record_info('tls-debug: mount enforcing', script_output($probe, proceed_on_failure => 1, timeout => 600));
    script_run('setenforce 0');
    record_info('tls-debug: mount permissive', script_output($probe, proceed_on_failure => 1, timeout => 600));
    # Leave the SUT in the product default so the following xfstests run still
    # reproduces the real failure.
    script_run('setenforce 1');
}

sub tls_debug_upload {
    script_run("tar -cJf /tmp/tls-debug.tar.xz -C /tmp " . basename($TLS_DEBUG_DIR), timeout => 120);
    upload_logs('/tmp/tls-debug.tar.xz', timeout => 300, log_name => 'tls-debug.tar.xz');
    # Re-enable the dontaudit rules disabled in tls_debug_install_tools.
    script_run('semodule -B', timeout => 600);
}

sub setup_ktls {
    my $tlshd_dir = '/etc/tlshd';
    assert_script_run("mkdir $tlshd_dir; cd $tlshd_dir");
    #Generate CA
    assert_script_run("openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ca.key -out ca.pem -subj \"/CN=NFS Test CA\"");
    #Generate server-CA
    assert_script_run("openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr  -subj \"/CN=nfs-server\" -addext \"subjectAltName=IP:127.0.0.1,IP:0:0:0:0:0:0:0:1\"");
    assert_script_run("openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 365 -extfile <(printf \"subjectAltName=IP:127.0.0.1,IP:0:0:0:0:0:0:0:1\")");
    #Generate client-CA(use for mtls, multi-way tls verification)
    assert_script_run("openssl req -new -nodes -newkey rsa:2048 -keyout client.key -out client.csr -subj \"/CN=nfs-client\" -addext \"subjectAltName=IP:127.0.0.1,IP:0:0:0:0:0:0:0:1\"");
    assert_script_run("openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client.pem -days 365 -extfile <(printf \"subjectAltName=IP:127.0.0.1,IP:0:0:0:0:0:0:0:1\")");
    script_run('cd -');
    # DEBUG BRANCH: loglevel raised from 1 to 3 so the journal carries the full
    # GnuTLS handshake trace.
    my $content = <<END;
[debug]
loglevel=3
tls=3
nl=1

[authenticate.client]
x509.truststore = /etc/tlshd/ca.pem
x509.certificate = /etc/tlshd/client.pem
x509.private_key = /etc/tlshd/client.key

[authenticate.server]
x509.truststore = /etc/tlshd/ca.pem
x509.certificate = /etc/tlshd/server.pem
x509.private_key = /etc/tlshd/server.key
END
    write_sut_file('/etc/tlshd.conf', $content);
    script_run("sed -i '/^ExecStart/ s|ExecStart=.*|ExecStart=/usr/sbin/tlshd -c /etc/tlshd.conf|' /usr/lib/systemd/system/tlshd.service");
    script_run('systemctl daemon-reload; systemctl enable tlshd.service; systemctl start tlshd.service');
    # DEBUG BRANCH
    tls_debug_install_tools;
    tls_debug_dump('1-after-tlshd-start');
}

sub setup_krb5 {
    script_run('hostname localhost');
    script_run('echo "127.0.0.1 localhost localhost.localdomain" >> /etc/hosts');
    my $content = <<END;
includedir  /etc/krb5.conf.d

[libdefaults]
    dns_canonicalize_hostname = false
    rdns = false
    verify_ap_req_nofail = true
    default_ccache_name = KEYRING:persistent:%{uid}
    default_realm = SUSETEST.COM
    dns_lookup_realm = false
    dns_lookup_kdc = false

[realms]
       SUSETEST.COM = {
        kdc = 127.0.0.1:88
        admin_server = 127.0.0.1:749
    }

[logging]
    kdc = FILE:/var/log/krb5/krb5kdc.log
    admin_server = FILE:/var/log/krb5/kadmind.log
    default = SYSLOG:NOTICE:DAEMON
END
    write_sut_file('/etc/krb5.conf', $content);

    #Config idmapd.conf
    $content = <<END;
[General]
Domain = susetest.com

[Mapping]
Nobody-User = nobody
Nobody-Group = nobody
END
    write_sut_file('/etc/idmapd.conf', $content);

    #create KDC database, start service and setup key
    script_run('kdb5_util create -s -P susetest -r SUSETEST.COM');
    script_run('systemctl start krb5kdc kadmind; systemctl enable krb5kdc kadmind');
    script_run('echo -e "susetest\nsusetest" | kadmin.local -q "addprinc root/admin@SUSETEST.COM"');
    script_run('kadmin.local -q "addprinc -randkey nfs/localhost@SUSETEST.COM"');
    script_run('kadmin.local -q "ktadd -k /etc/krb5.keytab nfs/localhost@SUSETEST.COM"');

    #create fsgqa/fsgqa2 users for some xfstests
    script_run('kadmin.local -q "addprinc -randkey fsgqa@SUSETEST.COM"');
    script_run('kadmin.local -q "addprinc -randkey fsgqa2@SUSETEST.COM"');
    script_run('kadmin.local -q "ktadd -k /etc/krb5.keytab fsgqa@SUSETEST.COM"');
    script_run('kadmin.local -q "ktadd -k /etc/krb5.keytab fsgqa2@SUSETEST.COM"');

    #verify the key
    script_run('klist -kte /etc/krb5.keytab');
    script_run('kadmin.local -q "getprinc nfs/localhost@SUSETEST.COM"');

    #get kerberos ticket and check
    script_run('kinit -k host/localhost@SUSETEST.COM');
    script_run('klist');
    script_run('kinit -k nfs/localhost@SUSETEST.COM');
    script_run('klist');

    script_run("systemctl restart nfs-idmapd");
    script_run("systemctl restart rpc-gssd");
    script_run("sleep 10");
}

sub setup_nfs_server {
    my $nfsversion = shift;
    if ($nfsversion =~ 'TLS') {
        setup_ktls;
    }
    if ($nfsversion =~ 'pnfs') {
        assert_script_run('mkdir -p /opt/export/test /opt/export/scratch /opt/nfs/test /opt/nfs/scratch && chown nobody:nogroup /opt/export/test /opt/export/scratch && echo \'/opt/export/test *(rw,pnfs,no_subtree_check,no_root_squash,fsid=1)\' >> /etc/exports && echo \'/opt/export/scratch *(rw,pnfs,no_subtree_check,no_root_squash,fsid=2)\' >> /etc/exports');
    }
    elsif ($nfsversion =~ 'krb5') {
        setup_krb5($nfsversion);
        assert_script_run('mkdir -p /opt/export/test /opt/export/scratch /opt/nfs/test /opt/nfs/scratch && chown nobody:nogroup /opt/export/test /opt/export/scratch && echo \'/opt/export/test *(rw,no_subtree_check,no_root_squash,sec=krb5:krb5i:krb5p,fsid=1)\' >> /etc/exports && echo \'/opt/export/scratch *(rw,no_subtree_check,no_root_squash,sec=krb5:krb5i:krb5p,fsid=2)\' >> /etc/exports');
        script_run("sed -i 's/RPCGSSDARGS=\"/RPCGSSDARGS=\"-vvv /' /etc/sysconfig/nfs");
        script_run("systemctl daemon-reload");
    }
    else {
        assert_script_run('mkdir -p /opt/export/test /opt/export/scratch /opt/nfs/test /opt/nfs/scratch && chown nobody:nogroup /opt/export/test /opt/export/scratch && echo \'/opt/export/test *(rw,no_subtree_check,no_root_squash,fsid=1)\' >> /etc/exports && echo \'/opt/export/scratch *(rw,no_subtree_check,no_root_squash,fsid=2)\' >> /etc/exports');
    }
    my $nfsgrace = get_var('NFS_GRACE_TIME', 15);
    assert_script_run("echo 'options lockd nlm_grace_period=$nfsgrace' >> /etc/modprobe.d/lockd.conf && echo 'options lockd nlm_timeout=5' >> /etc/modprobe.d/lockd.conf");

    if ($nfsversion =~ '3') {
        assert_script_run("echo 'MOUNT_NFS_V3=\"yes\"' >> /etc/sysconfig/nfs");
        assert_script_run("echo 'MOUNT_NFS_DEFAULT_PROTOCOL=3' >> /etc/sysconfig/autofs && echo 'OPTIONS=\"-O vers=3\"' >> /etc/sysconfig/autofs");
        assert_script_run("echo '[NFSMount_Global_Options]' >> /etc/nfsmount.conf && echo 'Defaultvers=3' >> /etc/nfsmount.conf && echo 'Nfsvers=3' >> /etc/nfsmount.conf");
        record_info('nfsmount.conf file', script_output("cat /etc/nfsmount.conf"));
    }
    else {
        assert_script_run("sed -i 's/NFSV4LEASETIME=\"\"/NFSV4LEASETIME=\"$nfsgrace\"/' /etc/sysconfig/nfs");
        my $content = <<END;
[nfsd]
grace-time=$nfsgrace
lease-time=$nfsgrace
END
        write_sut_file('/etc/nfs.conf', $content);
        if ($nfsversion =~ 'pnfs') {
            assert_script_run("echo '[NFSMount_Global_Options]' >> /etc/nfsmount.conf && echo 'Defaultvers=4.1' >> /etc/nfsmount.conf && echo 'Nfsvers=4.1' >> /etc/nfsmount.conf");
        }
        enable_rdma_in_nfs if $nfsversion =~ 'rdma';
    }
    assert_script_run('exportfs -a && systemctl restart rpcbind && systemctl enable nfs-server.service && systemctl restart nfs-server');
}

sub setup_nfs_client {
    my $nfsversion = shift;
    if ($nfsversion =~ 'rdma') {
        install_rdma_dependency;
        modprobe_rdma;
        link_add_rxe;
        rdma_record_info;
    }
    if ($nfsversion =~ 'rdma') {
        my $ip_addr = script_output("ip route | awk 'NR==2 {print \$9}'");
        script_run("mount -t nfs4 -o vers=4.1,minorversion=1,rdma $ip_addr:/opt/export/test /opt/nfs/test");
        record_info('pNFS_checkpoint', script_output('cat /proc/self/mountstats | grep pnfs', proceed_on_failure => 1));
        record_info('rdma mount checkpoint', script_output('cat /proc/fs/nfsfs/servers; grep opts: /proc/self/mountstats; grep xprt: /proc/self/mountstats', proceed_on_failure => 1));
    }
    elsif ($nfsversion =~ 'pnfs') {
        script_run('mount -t nfs4 -o vers=4.1,minorversion=1 localhost:/opt/export/test /opt/nfs/test');
        record_info('pNFS_checkpoint', script_output('cat /proc/self/mountstats | grep pnfs', proceed_on_failure => 1));
        record_info('/etc/exports', script_output('cat /etc/exports', proceed_on_failure => 1));
        record_info('nfsstat -m', script_output('nfsstat -m', proceed_on_failure => 1));
        script_run('umount /opt/nfs/test');
    }
    # There's a graceful time we need to wait before using the NFS server
    my $gracetime = script_output('cat /proc/fs/nfsd/nfsv4gracetime;');
    sleep($gracetime * 2);
    # DEBUG BRANCH: the AVC is only emitted once a handshake has been attempted,
    # so the second dump has to come after the mount probe.
    if ($nfsversion =~ 'TLS') {
        my ($vers_num) = $nfsversion =~ /-([\d.]+)/;
        tls_debug_mount_ab($vers_num || '4.2');
        tls_debug_dump('2-after-mount-probe');
        tls_debug_upload;
    }
}

sub run {
    my ($self) = @_;
    select_serial_terminal;

    # DO NOT set XFSTESTS_DEVICE if you don't know what's this mean
    # by default we use /home partition spaces for test, and don't need this setting
    my $device = get_var('XFSTESTS_DEVICE');
    my $loopdev = get_var('XFSTESTS_LOOP_DEVICE');
    my $zonedev = get_var('XFSTESTS_ZONE_DEVICE');

    my $filesystem = get_required_var('XFSTESTS');
    my %para;
    if (check_var('XFSTESTS', 'ocfs2')) {
        install_dependencies_ocfs2;
    }
    if (check_var('XFSTESTS', 'overlay')) {
        install_dependencies_overlayfs;
        script_run("echo export UNIONMOUNT_TESTSUITE=/opt/unionmount-testsuite >> $CONFIG_FILE");
    }
    if (check_var('XFSTESTS', 'nfs')) {
        disable_and_stop_service(opensusebasetest::firewall, ignore_failure => 1);
        set_var('XFSTESTS_TEST_DEV', mountpoint_to_partition('/'));
        post_env_info(join(' ', get_partition_size('/')));
        if (get_var('XFSTESTS_NFS_SERVER')) {
            server_configure_network($self);
            install_dependencies_nfs;
            setup_nfs_server("$NFS_VERSION");
            setup_nfs_client("$NFS_VERSION");
            mutex_create('xfstests_nfs_server_ready');
            wait_for_children;
        }
        elsif (get_var('PARALLEL_WITH')) {
            setup_static_mm_network('10.0.2.102/24');
            install_dependencies_nfs;
            assert_script_run('mkdir -p /opt/nfs/test /opt/nfs/scratch');
            $NFS_SERVER_IP = '10.0.2.101';
        }
        else {
            install_dependencies_nfs;
            setup_nfs_server("$NFS_VERSION");
            setup_nfs_client("$NFS_VERSION");
            $NFS_SERVER_IP = 'localhost';
            $NFS_SERVER_IP = '127.0.0.1' if $NFS_VERSION =~ 'TLS';    #ipv6 will make some issue for the test key
            $NFS_SERVER_IP = script_output("ip route | awk 'NR==2 {print \$9}'") if $NFS_VERSION =~ 'rdma';
        }
    }
    elsif ($device) {
        assert_script_run("parted $device --script -- mklabel gpt");
        $para{fstype} = $filesystem;
        $para{dev} = $device;
        post_env_info(do_partition_for_xfstests(\%para));
    }
    else {
        if ($loopdev) {
            $para{fstype} = $filesystem;
            $para{size} = script_output("df -h | grep /\$ | awk -F \" \" \'{print \$4}\'");
            $para{size} = str_to_mb($para{size});
            post_env_info(create_loop_device_by_rootsize(\%para));
        }
        elsif ($zonedev) {
            post_env_info(create_zoned_device());
        }
        else {
            my $home_size = script_output("df -h | grep home | awk -F \" \" \'{print \$2}\'");
            my %size_num = partition_amount_by_homesize($home_size);
            $para{fstype} = $filesystem;
            $para{amount} = $size_num{num};
            $para{size} = $size_num{size};
            $para{delhome} = 1;
            post_env_info(do_partition_for_xfstests(\%para));
        }
    }
    if (!get_var('XFSTESTS_NFS_SERVER')) {
        set_config;
    }
}

sub test_flags {
    return {fatal => 1};
}

1;
