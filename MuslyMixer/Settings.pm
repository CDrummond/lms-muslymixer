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
	'category'     => 'plugin.mipmixer',
	'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.mipmixer');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('MIPMIXER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MuslyMixer/settings/mipmixer.html');
}

sub prefs {
	return ($prefs, qw(port filter_genres ));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
}

1;

__END__
