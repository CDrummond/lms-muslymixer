package Plugins::MuslyMixer::Settings;

# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.muslymixer',
	'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.muslymixer');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('MUSLYMIXER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MuslyMixer/settings/muslymixer.html');
}

sub prefs {
	return ($prefs, qw(port filter_genres filter_xmas exclude_artists min_duration max_duration));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	return $class->SUPER::handler($client, $params);
}

1;

__END__
