#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for sticky upstreams, cookie domain with variables.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy upstream_sticky/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream u_host {
        server 127.0.0.1:8081;
        sticky cookie sticky domain=$host;
    }

    upstream u_arg {
        server 127.0.0.1:8081;
        sticky cookie sticky domain=$arg_d;
    }

    upstream u_header {
        server 127.0.0.1:8081;
        sticky cookie sticky domain=$http_x_domain;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /host {
            proxy_pass http://u_host;
        }

        location /arg {
            proxy_pass http://u_arg;
        }

        location /header {
            proxy_pass http://u_header;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 200 "backend";
        }
    }
}

EOF

$t->try_run('no sticky upstream')->plan(16);

###############################################################################

# valid domains are still used

is(cookie_attr(get('/host', 'example.com'), 'domain'), 'example.com',
	'host domain');
is(cookie_attr(get('/arg?d=example.com', 'localhost'), 'domain'),
	'example.com', 'arg domain');
is(cookie_attr(get('/header', 'localhost', 'example.com'), 'domain'),
	'example.com', 'header domain');

# internationalized domain names in punycode

is(cookie_attr(get('/host', 'xn--wgv71a119e.jp'), 'domain'),
	'xn--wgv71a119e.jp', 'host punycode domain');

# requests are still served with a sticky cookie

like(get('/host', 'example.com;Secure'), qr/^Set-Cookie: sticky=\w+/m,
	'host injection cookie');

TODO: {
local $TODO = 'not yet';

# a semicolon in the Host header passes ngx_http_validate_host()

ok(!injected(get('/host', 'example.com;Secure'), 'secure'),
	'host secure');
ok(!injected(get('/host', 'example.com;HttpOnly'), 'httponly'),
	'host httponly');
ok(!injected(get('/host', 'example.com;SameSite=None'), 'samesite'),
	'host samesite');
ok(!injected(get('/host', 'example.com;Max-Age=0'), 'max-age'),
	'host max-age');

# arguments are not unescaped, and may contain a slash unlike Host

ok(!injected(get('/arg?d=example.com;secure', 'localhost'), 'secure'),
	'arg secure');
ok(!injected(get('/arg?d=example.com;max-age=0', 'localhost'), 'max-age'),
	'arg max-age');
ok(!injected(get('/arg?d=example.com;path=/admin', 'localhost'), 'path'),
	'arg path');

# header values may also contain spaces

ok(!injected(get('/header', 'localhost', 'example.com; secure'), 'secure'),
	'header secure');
ok(!injected(get('/header', 'localhost', 'example.com; max-age=0'),
	'max-age'), 'header max-age');
unlike(cookie_attr(get('/header', 'localhost', 'example .com'), 'domain')
	// '', qr/ /, 'header space');

# not in punycode, the Host header with such a name is rejected

is(cookie_attr(get('/header', 'localhost',
	"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e.jp"), 'domain'), undef,
	'header utf-8 domain');

}

###############################################################################

sub get {
	my ($uri, $host, $domain) = @_;

	my $header = defined $domain ? "X-Domain: $domain\n" : '';

	return http(<<EOF);
GET $uri HTTP/1.0
Host: $host
$header
EOF
}

sub cookie {
	my ($r) = @_;

	my ($cookie) = $r =~ /^Set-Cookie: (sticky=.*?)\x0d?$/m;

	return $cookie;
}

sub cookie_attrs {
	my ($r) = @_;

	my $cookie = cookie($r);
	return () unless defined $cookie;

	my @attrs = split(/;/, $cookie);
	shift @attrs;

	return map { s/^\s+//; s/\s+$//; $_ } @attrs;
}

sub cookie_attr {
	my ($r, $name) = @_;

	foreach my $attr (cookie_attrs($r)) {
		my ($n, $v) = split(/=/, $attr, 2);
		return $v if lc($n) eq $name;
	}

	return undef;
}

sub injected {
	my ($r, $name) = @_;

	return scalar grep { /^\Q$name\E(=|$)/i } cookie_attrs($r);
}

###############################################################################
