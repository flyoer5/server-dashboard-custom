#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my $PORT = 1111;
my $DOCROOT = "/root/server-dashboard/dashboard";

$| = 1;

sub respond {
    my ($client, $status, $content_type, $body) = @_;
    my $headers = "HTTP/1.1 $status\r\n" .
                  "Content-Type: $content_type\r\n" .
                  "Content-Length: " . length($body) . "\r\n" .
                  "Cache-Control: no-cache\r\n" .
                  "Access-Control-Allow-Origin: *\r\n" .
                  "\r\n";
    print $client $headers . $body;
}

sub run_cmd {
    my ($cmd) = @_;
    my $out = `$cmd 2>/dev/null`;
    return $out // '';
}


sub read_proc_file {
    my ($path) = @_;
    return '' unless $path && -r $path;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $v = <$fh>;
    close $fh;
    $v //= '';
    $v =~ s/\0/ /g;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

sub proc_info {
    my ($pid) = @_;
    return { pid => '', cmd => '', cwd => '', exe => '' } unless $pid && $pid =~ /^\d+$/;
    my $cmd = read_proc_file("/proc/$pid/cmdline");
    my $cwd = readlink("/proc/$pid/cwd") || '';
    my $exe = readlink("/proc/$pid/exe") || '';
    my $cg = read_proc_file("/proc/$pid/cgroup");
    my $cid = '';
    if ($cg =~ m{(?:docker[-/]|docker/)([0-9a-f]{12,64})}) { $cid = $1; }
    return { pid => $pid, cmd => $cmd, cwd => $cwd, exe => $exe, container_id => $cid };
}

sub docker_name_map {
    my %m;
    my $out = run_cmd(q{docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'});
    for my $line (split /
/, $out) {
        next unless $line =~ /^([0-9a-f]{12,64})\s+(.+)$/;
        my ($id, $name) = ($1, $2);
        $m{$id} = $name;
        $m{substr($id, 0, 12)} = $name;
    }
    return %m;
}

sub docker_meta_map {
    my %m;
    my $out = run_cmd(q{docker ps -a --no-trunc --format '{{.ID}}	{{.Names}}	{{.Image}}	{{.Labels}}	{{.Mounts}}'});
    for my $line (split /
/, $out) {
        next if $line =~ /^\s*$/;
        my ($id, $name, $image, $labels, $mounts) = split /	/, $line, 5;
        next unless $id;
        my %meta = ( name => ($name || ''), image => ($image || ''), labels => ($labels || ''), mounts => ($mounts || '') );
        if (($labels || '') =~ /com\.docker\.compose\.project\.working_dir=([^,]+)/) { $meta{host_location} = $1; }
        elsif (($labels || '') =~ /com\.docker\.compose\.project\.config_files=([^,]+)/) { $meta{host_location} = $1; }
        elsif (($mounts || '') =~ m{(/[^,]+)}) { $meta{host_location} = $1; }
        my $inspect = run_cmd('docker inspect ' . shell_quote($name) . q{ --format '{{.HostConfig.RestartPolicy.Name}}	{{.HostConfig.NetworkMode}}' });
        chomp $inspect;
        my ($rp, $net) = split /	/, $inspect, 2;
        $meta{restart_policy} = $rp || 'no';
        $meta{network_mode} = $net || '';
        $m{$id} = \%meta;
        $m{substr($id, 0, 12)} = \%meta;
    }
    return %m;
}

sub systemd_unit_for_name {
    my ($name) = @_;
    return '' unless $name;
    my %map = (
        server_dashboard => 'server-dashboard.service',
        picoclaw_launch => 'picoclaw-launch.service',
        picoclaw => 'picoclaw-gateway.service',
        ssh => 'ssh.service',
        mihomo => 'mihomo.service',
        containerd => 'containerd.service',
        docker => 'docker.service',
    );
    return $map{$name} if $map{$name};
    return "$name.service";
}

sub systemd_meta {
    my ($name) = @_;
    my $unit = systemd_unit_for_name($name);
    return {} unless $unit;
    my $out = run_cmd("systemctl show " . shell_quote($unit) . " -p Id -p LoadState -p UnitFileState -p Restart -p FragmentPath -p ActiveState 2>/dev/null");
    return {} unless $out =~ /Id=/;
    my %m;
    for my $line (split /\n/, $out) {
        my ($k, $v) = split /=/, $line, 2;
        $m{$k} = $v // '';
    }
    return {} unless $m{Id} && ($m{LoadState} || '') eq 'loaded';
    return {
        unit => $m{Id} || $unit,
        unit_state => $m{UnitFileState} || '',
        restart_policy => $m{Restart} || '',
        unit_file => $m{FragmentPath} || '',
        active_state => $m{ActiveState} || '',
    };
}

sub enrich_systemd_meta {
    my ($svc) = @_;
    return if !$svc || $svc->{container_id};
    my $m = systemd_meta($svc->{name});
    return if !$m || !$m->{unit};
    $svc->{source} ||= 'systemd';
    $svc->{unit} ||= $m->{unit};
    $svc->{unit_state} ||= $m->{unit_state};
    $svc->{restart_policy} ||= $m->{restart_policy};
    $svc->{unit_file} ||= $m->{unit_file};
    $svc->{autostart} ||= (($m->{unit_state} || '') eq 'enabled' ? 'yes' : 'no');
    $svc->{auto_restart} ||= (($m->{restart_policy} || 'no') ne 'no' ? 'yes' : 'no');
}

sub add_port {
    my ($svc, $lis, $info) = @_;
    push @{$svc->{ports}}, { port => $lis->{port}, proto => $lis->{proto}, addr => $lis->{addr}, pid => ($lis->{pid} || '') };
    if ($info) {
        $svc->{pid} ||= $info->{pid} || '';
        $svc->{cmd} ||= $info->{cmd} || '';
        $svc->{cwd} ||= $info->{cwd} || '';
        $svc->{exe} ||= $info->{exe} || '';
        $svc->{container_id} ||= $info->{container_id} || '';
    }
}

# Collect service info
sub get_services {
    my %services;
    my %docker_names = docker_name_map();
    my %docker_meta = docker_meta_map();

    # Get running systemd services - only grab the actual unit lines
    my $svc_out = run_cmd("systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null");
    for my $line (split /\n/, $svc_out) {
        next if $line =~ /^\s*$/;
        next if $line =~ /^●/;
        next if $line =~ /^legend/i;
        next if $line =~ /^LOAD/i;
        next if $line =~ /^\d+ loaded/i;
        next unless $line =~ /loaded\s+active\s+running/;
        if ($line =~ /^(\S+\.service)\s+loaded\s+active\s+running\s+(.*)/) {
            my $name = $1;
            my $desc = $2 || '';
            $name =~ s/\.service$//;
            $name =~ s/^systemd-// if $name ne 'systemd';
            $services{$name} = { name => $name, description => $desc, ports => [] };
        }
    }

    # Get listening TCP/UDP ports with process info
    my @listens;
    my $tcp_out = run_cmd("ss -tlnp 2>/dev/null");
    for my $line (split /\n/, $tcp_out) {
        next if $line =~ /^\s*$/;
        next unless $line =~ /LISTEN/;
        if ($line =~ /LISTEN\s+\S+\s+\S+\s+(\S+):(\S+)\s+\S+\s+users:\(\("([^"]+)",pid=(\d+)/) {
            push @listens, { addr => $1, port => $2, proc => $3, pid => $4, proto => 'tcp' };
        } elsif ($line =~ /LISTEN\s+\S+\s+\S+\s+(\S+):(\S+)\s+\S+$/) {
            push @listens, { addr => $1, port => $2, proc => '', proto => 'tcp' };
        }
    }

    my $udp_out = run_cmd("ss -ulnp 2>/dev/null");
    for my $line (split /\n/, $udp_out) {
        next if $line =~ /^\s*$/;
        next unless $line =~ /UNCONN/;
        if ($line =~ /UNCONN\s+\S+\s+\S+\s+(\S+):(\S+)\s+\S+\s+.*users:\(\("([^"]+)",pid=(\d+)/) {
            push @listens, { addr => $1, port => $2, proc => $3, pid => $4, proto => 'udp' };
        }
    }

    # Match ports to services, or create entries for unknown processes
    for my $lis (@listens) {
        my $proc = $lis->{proc};
        my $info = proc_info($lis->{pid});
        my $cmd = $info->{cmd} || '';
        my $cwd = $info->{cwd} || '';
        my $container_id = $info->{container_id} || '';
        my $container_name = $container_id ? ($docker_names{$container_id} || $docker_names{substr($container_id,0,12)} || '') : '';
        my $container_meta = $container_id ? ($docker_meta{$container_id} || $docker_meta{substr($container_id,0,12)} || {}) : {};
        my $matched = 0;
        if ($proc) {
            # If a listening process belongs to a Docker container, show the container name
            # instead of the short in-container process name, especially for host-network containers.
            if ($container_name && $proc ne 'qq') {
                my $key = $container_name;
                $key =~ s/[^A-Za-z0-9_.-]/_/g;
                $services{$key} //= { name => $key, description => 'Docker container / ' . $proc, ports => [] };
                $services{$key}{container_name} ||= $container_name;
                $services{$key}{container_image} ||= ($container_meta->{image} || '');
                $services{$key}{host_location} ||= ($container_meta->{host_location} || '');
                $services{$key}{container_location} ||= ($cwd || '');
                $services{$key}{source} ||= 'docker';
                $services{$key}{restart_policy} ||= ($container_meta->{restart_policy} || 'no');
                $services{$key}{network_mode} ||= ($container_meta->{network_mode} || '');
                $services{$key}{autostart} ||= (($services{$key}{restart_policy} =~ /^(always|unless-stopped|on-failure)$/) ? 'yes' : 'no');
                $services{$key}{auto_restart} ||= (($services{$key}{restart_policy} =~ /^(always|unless-stopped|on-failure)$/) ? 'yes' : 'no');
                if (($proc =~ /^(uvicorn|gunicorn|node|python|python3)$/) && $lis->{proto} eq 'tcp') {
                    $services{$key}{url} ||= 'http://__HOST__:' . $lis->{port} . '/';
                }
                add_port($services{$key}, $lis, $info);
                $matched = 1;
            }

            # Normalize special process names first; do this before fuzzy service matching.
            if (!$matched && $proc eq 'picoclaw-launch') {
                $services{picoclaw_launch} //= { name => 'picoclaw_launch', description => 'PicoClaw Launch Daemon / Management WebUI', url => 'http://__HOST__:18800/', ports => [] };
                $services{picoclaw_launch}{url} ||= 'http://__HOST__:18800/';
                add_port($services{picoclaw_launch}, $lis, $info);
                $matched = 1;
            } elsif ($proc eq 'picoclaw') {
                $services{picoclaw} //= { name => 'picoclaw', description => 'PicoClaw AI Assistant', ports => [] };
                add_port($services{picoclaw}, $lis, $info);
                $matched = 1;
            } elsif ($proc eq 'mihomo') {
                $services{mihomo} //= { name => 'mihomo', description => 'mihomo Daemon / MetaCubeXD WebUI', url => 'http://__HOST__:9090/ui/', ports => [] };
                $services{mihomo}{url} ||= 'http://__HOST__:9090/ui/';
                add_port($services{mihomo}, $lis, $info);
                $matched = 1;
            } elsif ($proc eq 'perl' && $lis->{port} eq '1111') {
                $services{server_dashboard} //= { name => 'server_dashboard', description => 'Standalone Server Dashboard / WebUI', url => 'http://__HOST__:1111/', ports => [] };
                $services{server_dashboard}{url} ||= 'http://__HOST__:1111/';
                add_port($services{server_dashboard}, $lis, $info);
                $matched = 1;
            } elsif (($proc eq 'python3' || $proc eq 'python') && ($lis->{port} eq '6185' || $cmd =~ /AstrBot-src|main\.py/ || $cwd =~ /AstrBot-src/)) {
                $services{astrbot} //= { name => 'astrbot', description => 'AstrBot / WebUI and API', url => 'http://__HOST__:6185/', ports => [] };
                $services{astrbot}{url} ||= 'http://__HOST__:6185/';
                add_port($services{astrbot}, $lis, $info);
                $matched = 1;
            } elsif ($proc eq 'sshd') {
                $services{ssh} //= { name => 'ssh', description => 'OpenSSH Server', ports => [] };
                add_port($services{ssh}, $lis, $info);
                $matched = 1;
            } elsif ($proc eq 'qq') {
                my $token = run_cmd(q{docker logs --tail 300 napcat 2>/dev/null | sed -n 's/.*WebUi Token: //p' | tail -1});
                chomp $token;
                my $url = $token ? "http://" . "__HOST__" . ":6099/webui?token=$token" : "http://" . "__HOST__" . ":6099/webui";
                $services{napcat} //= { name => 'napcat', description => 'NapCat QQ Bot / WebUI', url => $url, ports => [] };
                $services{napcat}{container_name} ||= ($container_name || 'napcat');
                $services{napcat}{container_image} ||= ($container_meta->{image} || '');
                $services{napcat}{host_location} ||= ($container_meta->{host_location} || '');
                $services{napcat}{container_location} ||= ($cwd || '');
                $services{napcat}{source} ||= 'docker';
                $services{napcat}{restart_policy} ||= ($container_meta->{restart_policy} || 'no');
                $services{napcat}{network_mode} ||= ($container_meta->{network_mode} || '');
                $services{napcat}{autostart} ||= (($services{napcat}{restart_policy} =~ /^(always|unless-stopped|on-failure)$/) ? 'yes' : 'no');
                $services{napcat}{auto_restart} ||= (($services{napcat}{restart_policy} =~ /^(always|unless-stopped|on-failure)$/) ? 'yes' : 'no');
                add_port($services{napcat}, $lis, $info);
                $matched = 1;
            }

            if (!$matched) {
                for my $svc (keys %services) {
                    if (lc($proc) eq lc($svc) || lc($proc) eq lc($svc . '.service') ||
                        index(lc($svc), lc($proc)) >= 0 || index(lc($proc), lc($svc)) >= 0) {
                        add_port($services{$svc}, $lis, $info);
                        $matched = 1;
                        last;
                    }
                }
            }
        }
        if (!$matched && $proc) {
            $services{$proc} //= { name => $proc, description => '', ports => [] };
            add_port($services{$proc}, $lis, $info);
        }
    }

    # Remove entries without ports and without description
    my @result;
    for my $svc (sort keys %services) {
        my $s = $services{$svc};
        next if @{$s->{ports}} == 0;
        # Skip the garbage systemctl lines
        next if $s->{name} =~ /^(7|legend|load|\d+ loaded)/i;
        enrich_systemd_meta($s);
        $s->{source} ||= 'process';
        $s->{autostart} ||= 'unknown';
        $s->{auto_restart} ||= 'unknown';
        push @result, $s;
    }

    return \@result;
}

sub json_escape {
    my ($v) = @_;
    $v //= '';
    $v =~ s!\\!\\\\!g;
    $v =~ s!"!\\"!g;
    $v =~ s!\n!\\n!g;
    $v =~ s!\r!\\r!g;
    $v =~ s!\t!\\t!g;
    # JSON strings cannot contain raw control chars such as ANSI ESC (\x1b).
    $v =~ s!([\x00-\x08\x0b\x0c\x0e-\x1f])!sprintf('\\u%04x', ord($1))!eg;
    return $v;
}

sub services_to_json {
    my $services = shift;
    my @parts;
    for my $svc (@$services) {
        my $name = $svc->{name};
        my $desc = $svc->{description};
        my $url = $svc->{url} || '';
        my $pid = json_escape($svc->{pid} || '');
        my $cmd = json_escape($svc->{cmd} || '');
        my $cwd = json_escape($svc->{cwd} || '');
        my $exe = json_escape($svc->{exe} || '');
        my $container_id = json_escape($svc->{container_id} || '');
        my $container_name = json_escape($svc->{container_name} || '');
        my $container_image = json_escape($svc->{container_image} || '');
        my $host_location = json_escape($svc->{host_location} || '');
        my $container_location = json_escape($svc->{container_location} || '');
        my $source = json_escape($svc->{source} || '');
        my $autostart = json_escape($svc->{autostart} || '');
        my $auto_restart = json_escape($svc->{auto_restart} || '');
        my $restart_policy = json_escape($svc->{restart_policy} || '');
        my $network_mode = json_escape($svc->{network_mode} || '');
        my $unit = json_escape($svc->{unit} || '');
        my $unit_state = json_escape($svc->{unit_state} || '');
        my $unit_file = json_escape($svc->{unit_file} || '');
        $desc = json_escape($desc);
        $name = json_escape($name);
        $url = json_escape($url);
        my @port_parts;
        for my $p (@{$svc->{ports}}) {
            push @port_parts, sprintf('{"port":"%s","proto":"%s","addr":"%s","pid":"%s"}', $p->{port}, $p->{proto}, $p->{addr}, json_escape($p->{pid} || ''));
        }
        my $ports_json = '[' . join(',', @port_parts) . ']';
        push @parts, sprintf('{"name":"%s","description":"%s","url":"%s","pid":"%s","cmd":"%s","cwd":"%s","exe":"%s","container_id":"%s","container_name":"%s","container_image":"%s","host_location":"%s","container_location":"%s","source":"%s","autostart":"%s","auto_restart":"%s","restart_policy":"%s","network_mode":"%s","unit":"%s","unit_state":"%s","unit_file":"%s","ports":%s}', $name, $desc, $url, $pid, $cmd, $cwd, $exe, $container_id, $container_name, $container_image, $host_location, $container_location, $source, $autostart, $auto_restart, $restart_policy, $network_mode, $unit, $unit_state, $unit_file, $ports_json);
    }
    return '[' . join(',', @parts) . ']';
}


sub json_array_from_lines {
    my ($out) = @_;
    my @items;
    for my $line (split /\n/, $out) {
        next if $line =~ /^\s*$/;
        push @items, $line;
    }
    return '[' . join(',', @items) . ']';
}

sub get_docker_json {
    my $containers = run_cmd(q{docker ps -a --format '{{json .}}'});
    my $images = run_cmd(q{docker images --format '{{json .}}'});
    my $stats = run_cmd(q{docker stats --no-stream --format '{{json .}}'});
    return '{"containers":' . json_array_from_lines($containers) . ',"images":' . json_array_from_lines($images) . ',"stats":' . json_array_from_lines($stats) . '}';
}

sub shell_quote {
    my ($v) = @_;
    $v //= '';
    $v =~ s/'/'"'"'/g;
    return "'$v'";
}

sub docker_action_json {
    my ($op, $name) = @_;
    return '{"ok":false,"error":"missing name"}' if !$name;
    return '{"ok":false,"error":"invalid op"}' unless $op =~ /^(start|stop|restart)$/;
    return '{"ok":false,"error":"invalid container name"}' unless $name =~ /^[A-Za-z0-9_.-]+$/;
    my $cmd = 'docker ' . $op . ' ' . shell_quote($name) . ' 2>&1';
    my $out = `$cmd`;
    my $code = $? >> 8;
    $out = json_escape($out);
    if ($code == 0) {
        return '{"ok":true,"output":"' . $out . '"}';
    }
    return '{"ok":false,"error":"' . $out . '"}';
}


sub get_docker_logs {
    my ($name, $lines) = @_;
    $lines ||= 200;
    $lines =~ s/[^0-9]//g;
    $lines = 200 if $lines !~ /^[0-9]+$/;
    return '{"ok":false,"error":"invalid container name"}' unless $name =~ /^[A-Za-z0-9_.-]+$/;
    # Do not use run_cmd() here: it appends 2>/dev/null, which can hide
    # container stderr logs. Many apps, including uvicorn/logging, write logs
    # to stderr, so capture both stdout and stderr explicitly.
    my $cmd = qq{docker logs --tail $lines --timestamps } . shell_quote($name) . q{ 2>&1};
    my $out = `$cmd`;
    $out = json_escape($out);
    return '{"ok":true,"logs":"' . $out . '"}';
}


sub get_yunzai_json {
    my $pm2 = run_cmd(q{pm2 jlist});
    my $node = run_cmd(q{node -v}); chomp $node;
    my $pnpm = run_cmd(q{pnpm -v}); chomp $pnpm;
    my $valkey = run_cmd(q{valkey-cli ping}); chomp $valkey;
    my $port = run_cmd(q{ss -lntp | grep ':2536' || true}); chomp $port;
    my $conn = run_cmd(q{ss -tanp | grep ':2536' | grep ESTAB || true}); chomp $conn;
    my $pm2_enabled = run_cmd(q{systemctl is-enabled pm2-root 2>/dev/null}); chomp $pm2_enabled;
    my $pm2_active = run_cmd(q{systemctl is-active pm2-root 2>/dev/null}); chomp $pm2_active;
    my $pm2_dump = (-f '/root/.pm2/dump.pm2') ? 'yes' : 'no';
    my $config = json_escape(read_proc_file('/root/Yunzai/config/config/other.yaml'));
    my $bot = json_escape(read_proc_file('/root/Yunzai/config/config/bot.yaml'));
    $pm2 = $pm2 || '[]';
    return '{"pm2":' . $pm2 . ',"node":"' . json_escape($node) . '","pnpm":"' . json_escape($pnpm) . '","valkey":"' . json_escape($valkey) . '","port":"' . json_escape($port) . '","connections":"' . json_escape($conn) . '","pm2_enabled":"' . json_escape($pm2_enabled) . '","pm2_active":"' . json_escape($pm2_active) . '","pm2_dump":"' . json_escape($pm2_dump) . '","other_config":"' . $config . '","bot_config":"' . $bot . '"}';
}

sub yunzai_action_json {
    my ($op) = @_;
    return '{"ok":false,"error":"invalid op"}' unless $op =~ /^(start|stop|restart|save|enable_autostart|disable_autostart)$/;
    my $cmd;
    if ($op eq 'save') { $cmd = q{pm2 save 2>&1}; }
    elsif ($op eq 'enable_autostart') { $cmd = q{systemctl enable pm2-root 2>&1 && pm2 save 2>&1}; }
    elsif ($op eq 'disable_autostart') { $cmd = q{systemctl disable pm2-root 2>&1}; }
    else { $cmd = 'cd /root/Yunzai && pnpm ' . $op . ' 2>&1'; }
    my $out = `$cmd`;
    my $code = $? >> 8;
    $out = json_escape($out);
    return $code == 0 ? '{"ok":true,"output":"' . $out . '"}' : '{"ok":false,"error":"' . $out . '"}';
}

sub read_file_tail_lines {
    my ($path, $lines) = @_;
    return '' unless -f $path;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $buf = <$fh>;
    close $fh;
    $buf //= '';
    my @ls = split /\n/, $buf, -1;
    @ls = @ls > $lines ? @ls[-$lines..-1] : @ls;
    return join("\n", @ls);
}

sub yunzai_trim_to_last_start {
    my ($text) = @_;
    $text //= '';
    my $marker = 'TRSS-Yunzai v3.1.3 启动中...';
    my $idx = rindex($text, $marker);
    if ($idx < 0) { $idx = rindex($text, '启动中...'); }
    return $idx >= 0 ? substr($text, $idx) : $text;
}

sub read_file_delta_from_offset {
    my ($path, $offset) = @_;
    return ('', 0, 0) unless -f $path;
    $offset ||= 0;
    my $size = -s $path;
    return ('', 0, $size) if $offset > $size; # rotated or truncated
    open my $fh, '<:raw', $path or return ('', 0, 0);
    seek($fh, $offset, 0);
    local $/;
    my $buf = <$fh>;
    close $fh;
    $buf //= '';
    return ($buf, $offset, $size);
}

sub read_pm2_yunzai_tail {
    my ($lines) = @_;
    $lines ||= 100;
    $lines =~ s/[^0-9]//g;
    $lines = 100 if $lines !~ /^[0-9]+$/;
    $lines = 2000 if $lines > 2000;
    my $cmd = 'cd /root/Yunzai && pm2 logs TRSS-Yunzai --lines ' . $lines . ' --nostream --raw 2>&1';
    my $out = `$cmd`;
    $out //= '';
    return $out;
}

sub get_yunzai_logs {
    my ($mode, $lines, $out_off, $err_off) = @_;
    $mode ||= 'tail';
    $lines ||= 200;
    $lines =~ s/[^0-9]//g;
    $lines = 200 if $lines !~ /^[0-9]+$/;
    $lines = 2000 if $lines > 2000;
    $out_off =~ s/[^0-9]//g if defined $out_off;
    $err_off =~ s/[^0-9]//g if defined $err_off;
    my $outf = '/root/.pm2/logs/TRSS-Yunzai-out.log';
    my $errf = '/root/.pm2/logs/TRSS-Yunzai-error.log';

    if ($mode eq 'out_tail') {
        my $text = read_file_tail_lines($outf, $lines);
        my $out_size = (-f $outf) ? (-s $outf) : 0;
        my $err_size = (-f $errf) ? (-s $errf) : 0;
        return '{"ok":true,"mode":"out_tail","logs":"' . json_escape($text) . '","out_offset":"' . $out_size . '","err_offset":"' . $err_size . '"}';
    }

    if ($mode eq 'out_delta') {
        my ($out_delta, $out_reset, $out_size) = read_file_delta_from_offset($outf, $out_off || 0);
        my $err_size = (-f $errf) ? (-s $errf) : 0;
        return '{"ok":true,"mode":"out_delta","logs":"' . json_escape($out_delta) . '","out_offset":"' . $out_size . '","err_offset":"' . $err_size . '","out_reset":"' . $out_reset . '","err_reset":"0"}';
    }

    if ($mode eq 'follow_init') {
        my $out_size = (-f $outf) ? (-s $outf) : 0;
        my $err_size = (-f $errf) ? (-s $errf) : 0;
        return '{"ok":true,"mode":"follow_init","logs":"","out_offset":"' . $out_size . '","err_offset":"' . $err_size . '"}';
    }

    if ($mode eq 'delta') {
        my ($out_delta, $out_reset, $out_size) = read_file_delta_from_offset($outf, $out_off || 0);
        my ($err_delta, $err_reset, $err_size) = read_file_delta_from_offset($errf, $err_off || 0);
        my $text = '';
        $text .= $out_delta if length $out_delta;
        $text .= (length($text) && length($err_delta) ? "\n" : '') . $err_delta if length $err_delta;
        return '{"ok":true,"mode":"delta","logs":"' . json_escape($text) . '","out_offset":"' . $out_size . '","err_offset":"' . $err_size . '","out_reset":"' . $out_reset . '","err_reset":"' . $err_reset . '"}';
    }

    my $text = read_pm2_yunzai_tail($lines);
    my $out_size = (-f $outf) ? (-s $outf) : 0;
    my $err_size = (-f $errf) ? (-s $errf) : 0;
    return '{"ok":true,"mode":"tail","logs":"' . json_escape($text) . '","out_offset":"' . $out_size . '","err_offset":"' . $err_size . '"}';
}



sub url_decode {
    my ($v) = @_;
    $v //= '';
    $v =~ tr/+/ /;
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    return $v;
}

sub parse_qs {
    my ($qs) = @_;
    my %q;
    for my $pair (split /&/, ($qs || '')) {
        my ($k, $v) = split /=/, $pair, 2;
        $q{url_decode($k)} = url_decode($v // '');
    }
    return %q;
}

sub valid_tunnel_hostname {
    my ($h) = @_;
    return $h && $h =~ /^(?:[A-Za-z0-9-]+\.)+lgh123\.online$/ && $h !~ /\.\./;
}

sub valid_tunnel_service {
    my ($s) = @_;
    return $s && $s =~ m{^(https?|ssh|tcp)://[A-Za-z0-9_\.:-]+/?} && length($s) < 300;
}

sub read_tunnel_rules {
    my $cfg = read_proc_file('/etc/cloudflared/config.yml');
    my @rules;
    my $current_host = '';
    for my $line (split /\n/, $cfg) {
        if ($line =~ /^\s*-\s*hostname:\s*(.+?)\s*$/) {
            $current_host = $1; $current_host =~ s/["']//g;
        } elsif ($current_host && $line =~ /^\s*service:\s*(.+?)\s*$/) {
            my $svc = $1; $svc =~ s/["']//g;
            push @rules, { hostname => $current_host, service => $svc } if $svc !~ /^http_status:/;
            $current_host = '';
        }
    }
    return @rules;
}

sub write_tunnel_rules {
    my (@rules) = @_;
    my $cfg = read_proc_file('/etc/cloudflared/config.yml');
    my $tid = '';
    my $cred = '';
    my $proto = 'http2';
    if ($cfg =~ /^tunnel:\s*(\S+)/m) { $tid = $1; }
    if ($cfg =~ /^credentials-file:\s*(\S+)/m) { $cred = $1; }
    if ($cfg =~ /^protocol:\s*(\S+)/m) { $proto = $1; }
    return (0, 'missing tunnel id') unless $tid;
    return (0, 'missing credentials file') unless $cred;
    my $new = "tunnel: $tid\ncredentials-file: $cred\nprotocol: $proto\nno-autoupdate: true\n\ningress:\n";
    for my $r (@rules) {
        $new .= "  - hostname: $r->{hostname}\n    service: $r->{service}\n";
    }
    $new .= "  - service: http_status:404\n";
    open my $fh, '>:raw', '/etc/cloudflared/config.yml' or return (0, "write config failed: $!");
    print $fh $new;
    close $fh;
    return (1, 'ok');
}

sub tunnel_id_from_config {
    my $cfg = read_proc_file('/etc/cloudflared/config.yml');
    return $1 if $cfg =~ /^tunnel:\s*(\S+)/m;
    return '';
}

sub save_tunnel_rule_json {
    my ($original, $hostname, $service) = @_;
    return '{"ok":false,"error":"invalid hostname"}' unless valid_tunnel_hostname($hostname);
    return '{"ok":false,"error":"invalid service"}' unless valid_tunnel_service($service);
    my @rules = read_tunnel_rules();
    my @new;
    my $found = 0;
    for my $r (@rules) {
        if ($original && $r->{hostname} eq $original) { $found = 1; next; }
        next if (!$original && $r->{hostname} eq $hostname);
        push @new, $r;
    }
    push @new, { hostname => $hostname, service => $service };
    my ($ok, $msg) = write_tunnel_rules(@new);
    return '{"ok":false,"error":"' . json_escape($msg) . '"}' unless $ok;
    my $tid = tunnel_id_from_config();
    my $dnsout = `cloudflared tunnel route dns --overwrite-dns @{[shell_quote($tid)]} @{[shell_quote($hostname)]} 2>&1` if $tid;
    my $restart = `systemctl restart cloudflared 2>&1`;
    return '{"ok":true,"output":"' . json_escape(($dnsout || '') . $restart) . '"}';
}

sub delete_tunnel_rule_json {
    my ($hostname) = @_;
    return '{"ok":false,"error":"invalid hostname"}' unless valid_tunnel_hostname($hostname);
    my @rules = grep { $_->{hostname} ne $hostname } read_tunnel_rules();
    my ($ok, $msg) = write_tunnel_rules(@rules);
    return '{"ok":false,"error":"' . json_escape($msg) . '"}' unless $ok;
    my $dnsout = `cloudflared tunnel route dns delete @{[shell_quote($hostname)]} 2>&1`;
    my $restart = `systemctl restart cloudflared 2>&1`;
    return '{"ok":true,"output":"' . json_escape($dnsout . $restart) . '"}';
}

sub http_code_for_url {
    my ($url, $timeout) = @_;
    return '' unless $url;
    $timeout ||= 8;
    my $cmd = 'curl -k -L -sS -o /dev/null -w "%{http_code}" '
        . '--connect-timeout 3 --max-time ' . int($timeout) . ' --retry 1 --retry-delay 0 '
        . shell_quote($url);
    my $code = run_cmd($cmd);
    chomp $code;
    return ($code && $code =~ /^\d{3}$/) ? $code : '';
}

sub get_cloudflared_config_json {
    my $cfg = read_proc_file('/etc/cloudflared/config.yml');
    my @rules;
    my $current_host = '';
    for my $line (split /\n/, $cfg) {
        if ($line =~ /^\s*-\s*hostname:\s*(.+?)\s*$/) {
            $current_host = $1;
            $current_host =~ s/["']//g;
        } elsif ($current_host && $line =~ /^\s*service:\s*(.+?)\s*$/) {
            my $svc = $1;
            $svc =~ s/["']//g;
            if ($current_host ne '' && $current_host !~ /^http_status:/ && $svc !~ /^http_status:/) {
                push @rules, { hostname => $current_host, service => $svc };
            }
            $current_host = '';
        }
    }
    my @parts;
    for my $r (@rules) {
        my $hostname = $r->{hostname} || '';
        my $service = $r->{service} || '';
        my $dns = $hostname ? run_cmd('dig +short A ' . shell_quote($hostname) . ' ; dig +short CNAME ' . shell_quote($hostname)) : '';
        $dns =~ s/\n+$//;
        my $local_code = '';
        my $public_code = '';
        my $dns_ok = length($dns) ? 'yes' : 'no';
        my $local_ok = '';
        my $public_ok = '';
        my $synced = ($dns_ok eq 'yes') ? 'yes' : 'no';
        push @parts, '{"hostname":"' . json_escape($hostname) . '","service":"' . json_escape($service) . '","dns":"' . json_escape($dns) . '","dns_ok":"' . $dns_ok . '","local_code":"' . json_escape($local_code) . '","local_ok":"' . $local_ok . '","public_code":"' . json_escape($public_code) . '","public_ok":"' . $public_ok . '","synced":"' . $synced . '"}';
    }
    return '[' . join(',', @parts) . ']';
}

sub get_tunnel_status_json {
    my $status = run_cmd(q{systemctl is-active cloudflared 2>/dev/null}); chomp $status;
    my $enabled = run_cmd(q{systemctl is-enabled cloudflared 2>/dev/null}); chomp $enabled;
    my $tunnels = run_cmd(q{cloudflared tunnel list 2>&1});
    my $cfg = read_proc_file('/etc/cloudflared/config.yml');
    my $tid = '';
    if ($cfg =~ /^tunnel:\s*([A-Za-z0-9-]+)/m) { $tid = $1; }
    my $tname = '';
    for my $line (split /\n/, $tunnels) {
        if ($tid && $line =~ /^\Q$tid\E\s+(\S+)/) { $tname = $1; last; }
    }
    return '{"status":"' . json_escape($status || 'inactive') . '","enabled":"' . json_escape($enabled || 'unknown') . '","tunnel_id":"' . json_escape($tid) . '","tunnel_name":"' . json_escape($tname) . '","ingress":' . get_cloudflared_config_json() . ',"tunnels":"' . json_escape($tunnels) . '"}';
}

sub restart_tunnel_json {
    my $out = `systemctl restart cloudflared 2>&1`;
    my $code = $? >> 8;
    $out = json_escape($out);
    return $code == 0 ? '{"ok":true,"output":"' . $out . '"}' : '{"ok":false,"error":"' . $out . '"}';
}

sub handle_request {
    my ($client, $req) = @_;

    if ($req =~ /^GET\s+(\S+)\s+HTTP/) {
        my $path = $1;

        if ($path eq '/api/services') {
            my $services = get_services();
            my $json = services_to_json($services);
            respond($client, "200 OK", "application/json", $json);
            return;
        }

        if ($path eq '/api/yunzai') {
            my $json = get_yunzai_json();
            respond($client, "200 OK", "application/json", $json);
            return;
        }

        if ($path =~ m{^/api/yunzai/action\?(.+)$}) {
            my $qs = $1;
            my %q;
            for my $pair (split /&/, $qs) {
                my ($k, $v) = split /=/, $pair, 2;
                $v //= '';
                $v =~ tr/+/ /;
                $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
                $q{$k} = $v;
            }
            my $json = yunzai_action_json($q{op} || '');
            my $status = ($json =~ /^{"ok":true/) ? "200 OK" : "400 Bad Request";
            respond($client, $status, "application/json", $json);
            return;
        }

        if ($path =~ m{^/api/yunzai/logs\?(.+)$}) {
            my $qs = $1;
            my %q;
            for my $pair (split /&/, $qs) {
                my ($k, $v) = split /=/, $pair, 2;
                $v //= '';
                $v =~ tr/+/ /;
                $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
                $q{$k} = $v;
            }
            my $json = get_yunzai_logs($q{mode} || 'tail', $q{lines} || 200, $q{out_offset} || 0, $q{err_offset} || 0);
            respond($client, "200 OK", "application/json", $json);
            return;
        }


        if ($path eq '/api/tunnel/status') {
            my $json = get_tunnel_status_json();
            respond($client, "200 OK", "application/json", $json);
            return;
        }

        if ($path eq '/api/tunnel/restart') {
            my $json = restart_tunnel_json();
            my $status = ($json =~ /^{"ok":true/) ? "200 OK" : "400 Bad Request";
            respond($client, $status, "application/json", $json);
            return;
        }

        if ($path =~ m{^/api/tunnel/save\?(.+)$}) {
            my %q = parse_qs($1);
            my $json = save_tunnel_rule_json($q{original} || '', $q{hostname} || '', $q{service} || '');
            my $status = ($json =~ /^{"ok":true/) ? "200 OK" : "400 Bad Request";
            respond($client, $status, "application/json", $json);
            return;
        }

        if ($path =~ m{^/api/tunnel/delete\?(.+)$}) {
            my %q = parse_qs($1);
            my $json = delete_tunnel_rule_json($q{hostname} || '');
            my $status = ($json =~ /^{"ok":true/) ? "200 OK" : "400 Bad Request";
            respond($client, $status, "application/json", $json);
            return;
        }

        if ($path eq '/api/docker') {
            my $json = get_docker_json();
            respond($client, "200 OK", "application/json", $json);
            return;
        }


        if ($path =~ m{^/api/docker/logs\?(.+)$}) {
            my $qs = $1;
            my %q;
            for my $pair (split /&/, $qs) {
                my ($k, $v) = split /=/, $pair, 2;
                $v //= '';
                $v =~ tr/+/ /;
                $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
                $q{$k} = $v;
            }
            my $json = get_docker_logs($q{name} || '', $q{lines} || 200);
            my $status = ($json =~ /^{"ok":true/) ? "200 OK" : "400 Bad Request";
            respond($client, $status, "application/json", $json);
            return;
        }

        if ($path =~ m{^/api/docker/action\?(.+)$}) {
            my $qs = $1;
            my %q;
            for my $pair (split /&/, $qs) {
                my ($k, $v) = split /=/, $pair, 2;
                $v //= '';
                $v =~ tr/+/ /;
                $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
                $q{$k} = $v;
            }
            my $json = docker_action_json($q{op} || '', $q{name} || '');
            my $status = ($json =~ /^{"ok":true/) ? "200 OK" : "400 Bad Request";
            respond($client, $status, "application/json", $json);
            return;
        }

        my $file = $path;
        $file = '/index.html' if $file eq '/';
        $file =~ s/\.\.//g;
        $file = $DOCROOT . $file;

        if (-f $file) {
            open my $fh, '<:raw', $file or do {
                respond($client, "404 Not Found", "text/plain", "404 Not Found");
                return;
            };
            my $body;
            read($fh, $body, 102400);
            close $fh;

            my $ct = "text/plain";
            if ($file =~ /\.html?$/i)  { $ct = "text/html; charset=utf-8"; }
            elsif ($file =~ /\.css$/i) { $ct = "text/css; charset=utf-8"; }
            elsif ($file =~ /\.js$/i)  { $ct = "application/javascript; charset=utf-8"; }
            elsif ($file =~ /\.svg$/i) { $ct = "image/svg+xml"; }
            elsif ($file =~ /\.png$/i) { $ct = "image/png"; }

            respond($client, "200 OK", $ct, $body);
            return;
        }

        respond($client, "404 Not Found", "text/plain", "404 Not Found");
    }
}

# --- Main Server ---
my $server = IO::Socket::INET->new(
    LocalPort => $PORT,
    Type      => SOCK_STREAM,
    ReuseAddr => 1,
    Listen    => 10,
) or die "Cannot bind to port $PORT: $!\n";

print "Dashboard server running on http://0.0.0.0:$PORT\n";

my $sel = IO::Select->new($server);

while (1) {
    my @ready = $sel->can_read(5);
    for my $fh (@ready) {
        if ($fh == $server) {
            my $client = $server->accept();
            $client->autoflush(1);
            $sel->add($client);
        } else {
            my $req = '';
            my $ok = eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm(5);
                while (my $line = <$fh>) {
                    $req .= $line;
                    last if $line =~ /^\r?$/;
                }
                alarm(0);
                1;
            };
            if ($req) {
                handle_request($fh, $req);
            }
            $sel->remove($fh);
            close $fh;
        }
    }
}

close $server;