package Slim::Music::MusicFolderScan;

# $Id
#
# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use Slim::Utils::Misc;

# background scanning and cache prefilling of music information to speed up UI...

my @dummylist = ();
my $stillScanning = 0;

sub init {
	Slim::Music::Import::addImporter('FOLDER',\&startScan);

	# could probably base this on the existance/nonexistance of audiodir rather
	# than relying on startScan to abort a scan of a non-existant audiodir
	Slim::Music::Import::useImporter('FOLDER',1)
}

sub startScan {

	if (!defined(Slim::Utils::Prefs::get('audiodir')) or not -d Slim::Utils::Prefs::get("audiodir")) {
		$::d_info && msg("Skipping music folder scan - audiodir is undefined.\n");
		doneScanning();
		return;
	}

	if ($stillScanning) {
		$::d_info && msg("Scan already in progress. Aborting\n");
		Slim::Utils::Scan::stopAddToList(\@dummylist);
	}

	$stillScanning = 1;

	$::d_info && msg("Starting music folder scan\n");
	Slim::Utils::Scan::addToList(\@dummylist, Slim::Utils::Prefs::get('audiodir'), 1, 0, \&doneScanning, 0);
}

sub doneScanning {
	$::d_info && msg("finished background scan of music folder.\n");

	$stillScanning = 0;
	@dummylist = ();
	Slim::Music::Import::endImporter('FOLDER');
}

sub stillScanning {
	return $stillScanning;
}

1;

__END__
