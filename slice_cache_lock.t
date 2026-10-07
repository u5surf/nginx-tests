#!/usr/bin/perl

# Tests for slice filter with proxy_cache_lock.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket::INET;
use POSIX ();

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;
use Time::HiRes qw/ sleep /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache slice/);

my $v1 = '0123456789abcdef' x 4;
my $v2 = 'ABCDEFGHIJKLMNOP' x 4;
my $slices = length($v1) / 4;

my $refetch = refetch_supported($t)
	? 'proxy_cache_bypass $slice_refetch;' : '';

$t->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

daemon off;
worker_processes 2;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:1m;
    proxy_cache_key    \$uri\$is_args\$args\$slice_range;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        slice 4;

        proxy_set_header   Range  \$slice_range;

        proxy_cache   NAME;
        proxy_cache_valid   200 206  3s;
        proxy_cache_lock  on;

        $refetch

        location /lock/ {
            proxy_pass    http://127.0.0.1:8081;
        }

        location /stale/ {
            proxy_pass    http://127.0.0.1:8081;
            proxy_cache_use_stale  updating;
            proxy_cache_background_update  on;
        }

        location /age/ {
            slice 16;

            proxy_pass    http://127.0.0.1:8081;
            proxy_cache_lock_age  500ms;
            proxy_cache_valid   200 206  1m;
        }

        location /timeout/ {
            proxy_pass    http://127.0.0.1:8081;
            proxy_cache_lock_timeout  100ms;
        }
    }
}

EOF

$t->write_file('origin', 'v1');
$t->write_file('origin.log', '');

$t->run_daemon(\&http_daemon, $t->testdir());
$t->run()->plan(17);

$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my @r;

# parallel requests to an empty cache, each slice is fetched once

@r = parallel('/lock/t', 5);
is(complete(@r, $v1), 5, 'lock');
is(fetches($t, '/lock/t'), $slices, 'lock fetches');
is(rangeless($t, '/lock/t'), 0, 'lock ranges');

# parallel requests to stale slices, each slice is updated once

like(get('/stale/t'), qr/\Q$v1\E$/, 'stale prime');
sleep 4;

@r = parallel('/stale/t', 5);
is(complete(@r, $v1), 5, 'stale');
sleep 2;

is(fetches($t, '/stale/t'), 2 * $slices, 'stale fetches');
is(rangeless($t, '/stale/t'), 0, 'stale ranges');

# lock age expires while slices are fetched slowly, 4 slices of 16 bytes

@r = parallel('/age/t', 5);
is(complete(@r, $v1), 5, 'lock age');
is(rangeless($t, '/age/t'), 0, 'lock age ranges');

my $n = fetches($t, '/age/t');
cmp_ok($n, '>', 4, 'lock age expired');
like(get('/age/t'), qr/\Q$v1\E$/, 'lock age cached');
is(fetches($t, '/age/t'), $n, 'lock age cached fetches');

# lock timeout expires, slices are fetched without cache

@r = parallel('/timeout/t', 3);
is(complete(@r, $v1), 3, 'lock timeout');
is(rangeless($t, '/timeout/t'), 0, 'lock timeout ranges');

# outdated stale slices are fetched again by parallel requests,
# only once each

like(get('/stale/etag'), qr/\Q$v1\E$/, 'etag prime');
$t->write_file('origin', 'v2');
sleep 4;

get('/stale/etag', 'bytes=0-1');
sleep 0.5;
$n = fetches($t, '/stale/etag');

@r = parallel('/stale/etag', 5);
sleep 1;

is(complete(@r, $v2), 5, 'etag');
is(fetches($t, '/stale/etag') - $n, $slices - 1, 'etag fetches');

###############################################################################

sub parallel {
	my ($uri, $n) = @_;
	my @s = map { get($uri, start => 1) } 1 .. $n;
	return map { http_end($_) } @s;
}

sub complete {
	my $body = pop;
	return scalar(grep { /200 OK.*\Q$body\E$/s } @_);
}

sub fetched {
	my ($t, $uri) = @_;
	return grep { /^\Q$uri\E / } split /\n/, $t->read_file('origin.log');
}

sub fetches {
	return scalar(fetched(@_));
}

sub rangeless {
	return scalar(grep { !/\[bytes=/ } fetched(@_));
}

sub get {
	my ($uri, @extra) = @_;
	my $range = @extra % 2 ? "Range: " . shift(@extra) . "\n" : '';

	return http(<<EOF, @extra);
GET $uri HTTP/1.0
Host: localhost
$range
EOF
}

sub refetch_supported {
	my ($t) = @_;
	my $d = $t->testdir() . '/probe';

	# a separate prefix, so the test instance is not affected

	mkdir $d;
	mkdir "$d/logs";

	$t->write_file('probe/nginx.conf', <<'EOF');
events {
}

http {
    server {
        proxy_cache_bypass  $slice_refetch;
    }
}
EOF

	system("$Test::Nginx::NGINX -p $d/ -c $d/nginx.conf -e $d/logs/error.log"
		. " -t -q >/dev/null 2>&1");

	return $? == 0;
}

###############################################################################

sub http_daemon {
	my ($d) = @_;
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 128,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{CHLD} = 'IGNORE';

	while (my $client = $server->accept()) {
		my $pid = fork();
		die "fork() failed: $!\n" unless defined $pid;

		if ($pid) {
			close $client;
			next;
		}

		$client->autoflush(1);

		my ($uri, $range) = ('', '');

		while (<$client>) {
			$uri = $1 if /^GET (\S+)/;
			$range = $1 if /^Range: (.*?)\x0d?$/i;
			last if /^\x0d?\x0a?$/;
		}

		open my $v, '<', "$d/origin";
		my $ver = <$v>;
		close $v;

		open my $log, '>>', "$d/origin.log";
		print $log "$uri [$range]\n";
		close $log;

		sleep($uri =~ m!^/age/! ? 1 : 0.2);

		my $body = $ver eq 'v1' ? $v1 : $v2;
		my $len = length($body);

		my $h = "ETag: \"$ver\"\x0d\x0aConnection: close\x0d\x0a";

		if ($range =~ /bytes=(\d+)-(\d+)/) {
			my ($s, $e) = ($1, $2 < $len ? $2 : $len - 1);
			my $part = substr($body, $s, $e - $s + 1);

			print $client "HTTP/1.1 206 Partial Content\x0d\x0a$h"
				. "Content-Range: bytes $s-$e/$len\x0d\x0a"
				. "Content-Length: " . length($part) . "\x0d\x0a\x0d\x0a"
				. $part;

		} else {
			print $client "HTTP/1.1 200 OK\x0d\x0a$h"
				. "Content-Length: $len\x0d\x0a\x0d\x0a$body";
		}

		close $client;
		POSIX::_exit(0);
	}
}

###############################################################################
