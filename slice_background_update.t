#!/usr/bin/perl

# Tests for slice filter with proxy_cache_background_update.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Time::HiRes qw/ sleep /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache slice/);

# 16 slices of 4 bytes; the origin is a static file, its ETag changes
# along with the modification time

my $v1 = '0123456789abcdef' x 4;
my $v2 = 'ABCDEFGHIJKLMNOP' x 4;
my $slices = length($v1) / 4;

# $slice_refetch is used if supported, to bypass cache when an outdated
# slice is fetched again

my $refetch = refetch_supported($t)
	? 'proxy_cache_bypass $slice_refetch;' : '';

$t->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:1m;
    proxy_cache_key    \$uri\$is_args\$args\$slice_range;

    log_format  origin  "\$uri [\$http_range]";

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            slice 4;

            proxy_pass    http://127.0.0.1:8081;

            proxy_set_header   Range  \$slice_range;

            proxy_cache   NAME;
            proxy_cache_valid   200 206  3s;
            proxy_cache_use_stale  updating;
            proxy_cache_background_update  on;

            $refetch
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            access_log  %%TESTDIR%%/origin.log  origin;
        }
    }
}

EOF

$t->write_file('origin.log', '');

origin($t, 't', $v1, 1);
origin($t, 'etag', $v1, 1);
origin($t, 'middle', $v1, 1);
origin($t, 'ka', $v1, 1);

$t->run()->plan(16);

###############################################################################

# background update of a stale slice must request the slice range,
# and the result must be cached under the slice key

like(get('/t'), qr/200 OK.*\Q$v1\E$/s, 'prime');
is(fetches($t, '/t'), $slices, 'prime fetches');

sleep 4;

like(get('/t'), qr/200 OK.*\Q$v1\E$/s, 'stale');
sleep 1;

my @u = fetched($t, '/t');
splice(@u, 0, $slices);
is(scalar(grep { !/\[bytes=/ } @u), 0, 'background update with range');
is(scalar(@u), $slices, 'background update of each slice');

like(get('/t'), qr/200 OK.*\Q$v1\E$/s, 'updated');
sleep 0.5;
is(fetches($t, '/t'), 2 * $slices, 'updated slices cached');

# the origin is changed, while only the first slice is updated in cache;
# other slices are stale with the old ETag

like(get('/etag'), qr/200 OK.*\Q$v1\E$/s, 'etag prime');
origin($t, 'etag', $v2, 2);
sleep 4;

like(get('/etag', 'bytes=0-1'), qr/206 .*01$/s, 'etag first slice');
sleep 0.5;

my $n = fetches($t, '/etag');

like(get('/etag'), qr/200 OK.*\Q$v2\E$/s, 'etag outdated slices');
sleep 1;

is(fetches($t, '/etag') - $n, $slices - 1,
	'etag one fetch per outdated slice');

like(get('/etag'), qr/200 OK.*\Q$v2\E$/s, 'etag cached');

# the same, with keepalive: the next request on the connection
# must not be blocked

like(get('/ka'), qr/200 OK.*\Q$v1\E$/s, 'keepalive prime');
origin($t, 'ka', $v2, 2);
sleep 4;
get('/ka', 'bytes=0-1');
sleep 0.5;

my $r = http(<<EOF);
GET /ka HTTP/1.1
Host: localhost

GET /ka HTTP/1.1
Host: localhost
Connection: close

EOF

is(() = $r =~ /\Q$v2\E/g, 2, 'keepalive');

# the first slice is outdated, while one in the middle is updated;
# a response cannot be fixed then, but subsequent ones should be

like(get('/middle'), qr/200 OK.*\Q$v1\E$/s, 'middle prime');
origin($t, 'middle', $v2, 2);
sleep 4;
get('/middle', 'bytes=32-33');
sleep 0.5;

my $ok = 0;

for my $i (1 .. 4) {
	$ok = $i, last if get('/middle') =~ /200 OK.*\Q$v2\E$/s;
	sleep 0.5;
}


ok($ok, 'outdated first slice recovered');

###############################################################################

sub origin {
	my ($t, $name, $body, $mtime) = @_;
	my $d = $t->testdir();

	$t->write_file($name, $body);
	utime($mtime * 1000, $mtime * 1000, "$d/$name");
}

sub fetched {
	my ($t, $uri) = @_;
	return grep { /^\Q$uri\E / } split /\n/, $t->read_file('origin.log');
}

sub fetches {
	return scalar(fetched(@_));
}

sub get {
	my ($uri, $range) = @_;
	$range = $range ? "Range: $range\n" : '';

	return http(<<EOF);
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
