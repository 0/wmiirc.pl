#!/usr/bin/env perl

use strict;
use warnings;

use threads;

use 5.010;

use File::Basename; # fileparse
use File::Temp qw(tempfile);
use IO::Socket::UNIX;
use Lib::IXP qw(:subs :consts);
use List::MoreUtils qw(uniq);
use List::Util qw(first);
use POSIX qw(setsid strftime);
use Time::HiRes qw(usleep);

$SIG{CHLD} = 'IGNORE';

pipe EVENT_READ, EVENT_WRITE;

my $CLIENT;

sub ycreate {
	my ($file, $data) = @_;
	xcreate($CLIENT, $file, $data);
}

sub yremove {
	my ($file) = @_;
	xremove($CLIENT, $file);
}

sub ylist {
	my ($dir) = @_;
	map { $_->{name} } @{(xls($CLIENT, $dir))};
}

sub yread {
	my ($file) = @_;
	xread($CLIENT, $file, -1);
}

sub ywrite {
	my ($file, $data) = @_;
	xwrite($CLIENT, $file, $data);
}

sub launch_external {
	my $pid = fork();

	if (not defined $pid) {
		die 'Couldn\'t fork';
	} elsif (not $pid) {
		setsid() or die 'Couldn\'t setsid';
		close(STDOUT);
		close(STDERR);
		exec(@_);
		exit;
	}
}

sub gen_proglist {
	my $path = shift || $ENV{PATH};

	my ($proglist_fh, $proglist_file) = tempfile();
	my @path = split /:/, $path;
	my @progs = ();

	for my $p (@path) {
		push(@progs, map { (fileparse($_))[0] } glob("$p/*"));
	}

	print $proglist_fh join("\n", sort(uniq(@progs)), '');

	return $proglist_file;
}

sub all_tags {
	return grep { !/^sel$/ } ylist('/tag');
}

sub tagmenu {
	my $tags = join('\\\\n', all_tags());
	return `echo -e $tags | wimenu`;
}

sub cur_tag_info {
	my $ctl = yread('/tag/sel/ctl');
	return split('\n', $ctl);
}

sub cur_tag {
	return (cur_tag_info())[0];
}

sub extract_colors {
	substr(shift, 0, 23);
}

sub shift_tag {
	my $dir = shift;

	my @tags = all_tags();
	my $cur = cur_tag();

	$tags[((first {$tags[$_] eq $cur} 0..$#tags) + $dir) % @tags];
}

my @tag_stack;

sub update_tag_stack {
	my ($tag) = @_;

	my @temp_stack = grep { !/^${tag}$/ } @tag_stack;
	push (@temp_stack, $tag);
	@tag_stack = @temp_stack;
}

my $VLC_SOCK = '/tmp/vlc.sock';

sub vlc_cmd {
	my ($cmd) = @_;

	my $sock = IO::Socket::UNIX->new(Peer => $VLC_SOCK) or return;
	print $sock $cmd;
}

### Change current directory

chdir($ENV{HOME});

### Set some values

my $USER = $ENV{USER};
my $DISPLAY = (split(/\./, $ENV{DISPLAY}))[0];
$CLIENT = "unix!/tmp/ns.$USER.$DISPLAY/wmii";

my $proglist_file = gen_proglist();

### General configuration

my $term='urxvt';

my $normal_fg = '#ffffff';
my $normal_bg = '#000000';
my $normal_brd = '#444444';

my $focus_brd = '#ffffff';

my $urgent_bg = '#ff6600';

my $offline_bg = '#444444';

my $normal_colors = "$normal_fg $normal_bg $normal_brd";
my $focus_colors = "$normal_fg $normal_bg $focus_brd";
my $urgent_colors = "$normal_fg $urgent_bg $normal_brd";
my $offline_colors = "$normal_fg $offline_bg $normal_brd";

my $battery_path = '/sys/class/power_supply/BAT1';

my %key = (
	mod     => 'Mod4',
	mod_alt => 'Mod1',
	left    => 'h',
	down    => 'j',
	up      => 'k',
	right   => 'l',
	toggle  => 'space',
);

my $loadavg_alert = 4;
my $loadavg_warn = 2;

### Init wmii

ywrite('/event', 'Start wmiirc');

ywrite('/ctl', "normcolors $normal_colors");
ywrite('/ctl', "focuscolors $focus_colors");
ywrite('/ctl', "grabmod $key{mod}");

### Set up keys

my %keys = (
	"$key{mod}-Return" => sub {
		launch_external($term);
	},

	"$key{mod}-Shift-c" => sub {
		ywrite('/client/sel/ctl', 'kill');
	},

	"$key{mod}-d" => sub {
		ywrite('/tag/sel/ctl', 'colmode sel default-max');
	},
	"$key{mod}-s" => sub {
		ywrite('/tag/sel/ctl', 'colmode sel stack-max');
	},
	"$key{mod}-m" => sub {
		ywrite('/tag/sel/ctl', 'colmode sel stack+max');
	},
	"$key{mod}-f" => sub {
		ywrite('/client/sel/ctl', 'Fullscreen toggle');
	},

	"$key{mod}-t" => sub {
		my $result = tagmenu();
		ywrite('/ctl', "view $result");
	},
	"$key{mod}-Shift-t" => sub {
		my $result = tagmenu();
		ywrite('/client/sel/tags', $result);
	},

	"$key{mod}-a" => sub {
		my @tags = ylist('/lbar');
		for my $tag (@tags) {
			my $colors = extract_colors(yread("/lbar/$tag"));
			if ($colors eq $urgent_colors) {
				ywrite('/ctl', "view $tag");
				last;
			}
		}
	},

	"$key{mod}-Left" => sub {
		my $new_tag = shift_tag(-1);
		ywrite('/ctl', "view $new_tag");
	},
	"$key{mod}-Right" => sub {
		my $new_tag = shift_tag(+1);
		ywrite('/ctl', "view $new_tag");
	},

	"$key{mod}-Tab" => sub {
		return if @tag_stack < 2;

		my $prev_tag = $tag_stack[-2];
		ywrite('/ctl', "view $prev_tag");
	},

	"$key{mod}-p" => sub {
		launch_external("\$(wimenu <$proglist_file)");
	},

	"$key{mod_alt}-space" => sub {
		launch_external("$term -e alsamixer");
	},

	"$key{mod}-w" => sub {
		if (grep {!/^select ~$/} cur_tag_info()) {
			ywrite('/tag/sel/ctl', 'select ~');
		}
		launch_external('~/uw-weather/fetch.pl | xmessage -default okay -center -file -');
	},

	'XF86AudioMute' => sub {
		launch_external('amixer set Master toggle');
	},

	'XF86MonBrightnessDown' => sub {
		launch_external('setlap \'b!d\' q');
	},
	'XF86MonBrightnessUp' => sub {
		launch_external('setlap \'b!u\' q');
	},

	'Control-Shift-Up' => sub {
		launch_external('setxkbmap -layout us');
	},
	'Control-Shift-Down' => sub {
		launch_external('setxkbmap -layout ru');
	},

	'Print' => sub {
		launch_external('import /tmp/foo.png');
	},

	'XF86AudioPlay' => sub {
		vlc_cmd('pause');
	},
	'Shift-XF86AudioPlay' => sub {
		vlc_cmd('play');
	},
	'XF86AudioStop' => sub {
		vlc_cmd('stop');
	},
	'XF86AudioNext' => sub {
		vlc_cmd('next');
	},
	'XF86AudioPrev' => sub {
		vlc_cmd('prev');
	},
	'Shift-XF86AudioNext' => sub {
		vlc_cmd('key key-jump+short');
	},
	'Shift-XF86AudioPrev' => sub {
		vlc_cmd('key key-jump-short');
	},
);

$keys{Caps_Lock} = $keys{"$key{mod}-t"};

for my $dir ('left', 'down', 'up', 'right', 'toggle') {
	$keys{"$key{mod}-$key{$dir}"} = sub {
		ywrite('/tag/sel/ctl', "select $dir");
	};
	$keys{"$key{mod}-shift-$key{$dir}"} = sub {
		ywrite('/tag/sel/ctl', "send sel $dir");
	};
}

for my $tag (0..9) {
	$keys{"$key{mod}-$tag"} = sub {
		ywrite('/ctl', "view $tag");
	};
	$keys{"$key{mod}-Shift-$tag"} = sub {
		ywrite('/client/sel/tags', $tag);
	};
}

ywrite('/keys', join("\n", keys %keys) . "\n");

### Set up statuses

my @statuses = (
	sub { # spacer
	},
	sub { # speakers
		my $bar = "/rbar/$_[0]";
		for (;;) {
			my ($volume, $on);

			open(MIXER, 'amixer get Master |');
			while (<MIXER>) {
				if (/front left:.*?\[(-?[\d.]+)dB\].*?\[(o[fn]+)\]/i) {
					($volume, $on) = ($1, $2 ne 'off');
					last;
				}
			}
			close(MIXER);

			my $colors;
			if ($on) {
				$colors = sprintf("$normal_fg #0000%02x $normal_brd", int(255 * (46.5 + $volume) / 46.5));
			} else {
				$colors = $offline_colors;
			}

			ywrite($bar, "$colors ${volume} dB");
			usleep(2_000_000);
		}
	},
	sub { # load average
		my $bar = "/rbar/$_[0]";
		for (;;) {
			open(LOADAVG, '/proc/loadavg');
			my $la = (split(' ', <LOADAVG>))[0];
			close(LOADAVG);

			my $colors;
			if ($la > $loadavg_alert) {
				$colors = "$normal_fg #ff0000 #ff0000";
			} elsif ($la > $loadavg_warn) {
				my $bg_r = int(255 * ($la - $loadavg_warn) / ($loadavg_alert - $loadavg_warn));
				$colors = sprintf("$normal_fg #%02x0000 $normal_brd", $bg_r);
			} else {
				$colors = $normal_colors;
			}

			ywrite($bar, "$colors $la");
			usleep(5_000_000);
		}
	},
	sub { # backlight
		my $bar = "/rbar/$_[0]";
		for (;;) {
			open(BACKLIGHT, '/sys/class/backlight/acpi_video0/brightness');
			my $brightness = <BACKLIGHT>;
			close(BACKLIGHT);

			ywrite($bar, "b$brightness");
			usleep(1_000_000);
		}
	},
	sub { # cpu temp
		my $bar = "/rbar/$_[0]";
		for (;;) {
			open(CPU_TEMP, '/sys/class/thermal/thermal_zone0/temp');
			my $temp = <CPU_TEMP> / 1000;
			close(CPU_TEMP);

			my $colors;
			if ($temp > 75) {
				$colors = "$normal_fg #ff0000 #ff0000";
			} elsif ($temp >= 55) {
				my $bg_r = int(255 * ($temp - 55) / 20);
				$colors = sprintf("$normal_fg #%02x0000 $normal_brd", $bg_r);
			} else {
				$colors = $normal_colors;
			}

			ywrite($bar, "$colors $temp C");
			usleep(1_000_000);
		}
	},
	sub { # battery
		my $bar = "/rbar/$_[0]";
		for (;;) {
			if (-e $battery_path) {
				open(BATTERY, "$battery_path/status");
				my $status = <BATTERY>;
				open(BATTERY, "$battery_path/energy_now");
				my $now = <BATTERY>;
				open(BATTERY, "$battery_path/energy_full");
				my $full = <BATTERY>;
				close(BATTERY);

				my $ratio = $now / $full;

				my $border;
				given ($status) {
					when (/^charging/i) { $border = '#00ff00' };
					when (/^full/i)     { $border = $normal_brd };
					default             { $border = '#ff0000' };
				}

				my $bg_r = int(255 * (1 - $ratio));

				ywrite($bar, sprintf("$normal_fg #%02x0000 $border %.3f%%", $bg_r, 100 * $ratio));
			} else {
				ywrite($bar, "$offline_colors ???%");
			}
			usleep(5_000_000);
		}
	},
	sub { # time
		my $bar = "/rbar/$_[0]";
		for (;;) {
			ywrite($bar, strftime('%d %a %H:%M:%S', localtime));
			usleep(500_000);
		}
	},
);

### Set up lbar for existing tags

yremove("/lbar/$_") for ylist('/lbar');

my $cur_tag = cur_tag();
for my $tag (all_tags()) {
	if ($tag eq $cur_tag) {
		ycreate("/lbar/$tag", "$focus_colors $tag");
	} else {
		ycreate("/lbar/$tag", "$normal_colors $tag");
	}
}

### And get the statuses going

yremove("/rbar/$_") for ylist('/rbar');

for my $status (0..$#statuses) {
	ycreate("/rbar/$status", '');

	my $thr = threads->create($statuses[$status], $status);
	$thr->detach();
}

### Event loop!

my $event_child = fork();

if (not defined $event_child) {
	die 'Couldn\'t fork';
} elsif (not $event_child) {
	# Since /event doesn't get EOF until wmii exits, this hangs forever.
	xread($CLIENT, '/event', fileno(EVENT_WRITE));
	exit; # But just in case.
}

END {
	# Kill the child that has the xread call for /event
	kill(9, $event_child);
}

while (<EVENT_READ>) {
	if (/^Start wmiirc$/) {
		last;

	} elsif (/^Key (.*)$/) {
		if (defined $keys{$1}) {
			$keys{$1}();
		}
	} elsif (/^CreateTag (.*)/) {
		ycreate("/lbar/$1", "$normal_colors $1");
	} elsif (/^DestroyTag (.*)/) {
		yremove("/lbar/$1");
	} elsif (/^FocusTag (.*)/) {
		update_tag_stack($1);
		ywrite("/lbar/$1", "$focus_colors $1");
	} elsif (/^UnfocusTag (.*)/) {
		ywrite("/lbar/$1", "$normal_colors $1");
	} elsif (/^UrgentTag [^ ]+ (.*)/) {
		if (cur_tag() ne $1) {
			ywrite("/lbar/$1", "$urgent_colors $1");
		}
	} elsif (/^NotUrgentTag [^ ]+ (.*)/) {
		if (cur_tag() ne $1) {
			ywrite("/lbar/$1", "$normal_colors $1");
		}
	} elsif (/^LeftBarMouseDown \d+ (.*)/) {
		ywrite('/ctl', "view $1");
	}
}
