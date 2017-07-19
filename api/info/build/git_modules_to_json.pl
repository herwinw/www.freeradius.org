#! /usr/bin/perl

#** @file git_modules_to_json.pl
# @brief Build tree of json files for the web site api to read.
#
# Scans the FreeRADIUS git repository for all sorts of goodies and writes it
# out in json files for the lua API to read.
#
# Written in perl to make Arran happy.
#
# @author Matthew Newton
# @date 2017-07-11
#*

use strict;
use Data::Dumper;

use Git::Repository;

my $gitdir = "/srv/freeradius-server";

my $repo = Git::Repository->new( work_tree => $gitdir );


#** @function version_compare ($version_a, $version_b)
# @brief Compare two version numbers
#
# Equivalent to perl's "<=>" and "cmp" operators for FreeRADIUS version
# numbers. Given two version numbers (e.g. "3.0.5" and "2.2.8") returns -1, 0
# or 1 depending on whether the first is less than, equal to or greater than
# the second.
#
# @params $version_a	Version number
# @params $version_b	Version number
#
# @retval $cmp		-1, 0 or 1
#*

sub version_compare
{
	my ($va, $vb) = @_;

	# $va and $vb are in the form "1.2.3"
	#
	my @sa = split /\./, $va;
	my @sb = split /\./, $vb;

	# go through each component of the version number, if they are the
	# same then jump to the next, otherwise comparison can stop here.
	#
	for (my $i = 0; $i < 3; $i++) {
		next if $sa[$i] == $sb[$i];
		return $sa[$i] <=> $sb[$i];
	}

	# both versions are the same
	#
	return 0;
}


#** @function get_module_readme ($repo, $blob)
# @brief Retrieve module README.md and parse it
#
# Given a git blob of a README.md file, pulls it from the git repository and
# parses it into a usable data structure.
#
# @params $repo		Git::Repository reference
# @params $blob		Git blob
#
# @retval $readme	Hash reference of README data
#*

sub get_module_readme
{
	my ($repo, $blob) = @_;

	my $data = $repo->command("show" => $blob)->stdout;

# this is rather a TODO for now.
# parse the README, and return a hash of the different sections

# for the time being, just return the whole file.
	my @lines = $data->getlines();
	return join "", @lines;
}


#** @function get_releases ($repo)
# @brief Get all release tags from the git repository
#
# Scans the git repository for all release tags (that begin 'release_')
# and returns them in a hash where the keys are the version number and
# the values are the release tag.
#
# @params $repo		Git::Repository reference
#
# @retval $%releases	Hash reference of version => release tag
#*

sub get_releases
{
	my $repo = shift;

	my @tags = map {chomp $_; $_}
		$repo->command("tag" => '-l')->stdout->getlines();

	my %release = map {/^release[_.](\d+)[_.](\d+)[_.](\d+)$/ ? ("$1.$2.$3", $_) : ()} @tags;

	return \%release;
}


#** @function get_release_modules ($repo, $reltag)
# @brief Get all modules included in a particular release
#
# Looks at all directories under src/modules in a given release and returns a
# hash of all modules. Key is the module name, and value is a hash with the
# module name, parent module name (e.g. rlm_sql for rlm_sql_sqlite) and readme
# for the module if available.
#
# @params $repo		Git::Repository reference
# @params $reltag	Git tag name or object
#
# @retval $%modules	Hash reference of module name => module information
#*

sub get_release_modules
{
	my ($repo, $reltag) = @_;

	# run git ls-tree to find all subdirectories of src/modules for a
	# particular git tag, and get the data as an array of hashes
	#
	my $trees = $repo->command("ls-tree" => "-rt", "$reltag", "src/modules/")->stdout;
	my @objects = grep {$$_{path} =~ /^src\/modules\// and
				($$_{type} eq "tree" or $$_{path} =~ m+/README.md$+)}
		map {my @x = split /\s+/; {
			mode => $x[0],
			type => $x[1],
			hash => $x[2],
			path => $x[3],
		}}
		$trees->getlines();

	# new data structure to hold all the module details in
	my $modules = {};

	# go through each git object and work out which modules exist
	foreach my $o (@objects) {
		next unless $$o{path} =~ m+^src/modules/+;

		my @components = split /\//, $$o{path};

		# get the relevant module name
		#
		my $name;
		if ($$o{type} eq "tree") {
			# the main module name will always be at the end of the path
			# and begin with rlm_ or proto_
			$name = $components[$#components];
		} else {
			# we only care about README files, so short circuit if not
			next unless $components[$#components] eq "README.md";
			$name = $components[$#components-1];
		}

		# only interested in certain directories
		#
		next unless $name =~ /^(rlm|proto)_/;

		my $module = $modules->{$name} || {};
		$module->{name} = $name;

		# find the parent for submodules
		#
		if ($$o{type} eq "tree" and $#components > 2) {
			$module->{parent} = @components[2];
		}

		# get the module readme
		#
		if ($$o{type} eq "blob") {
			$module->{readme} = get_module_readme($repo, $$o{hash});
		}

		$modules->{$name} = $module;
	}

	return $modules;
}


#** @function build_modules_repository ($modrepo, $modules, $release)
# @brief Add data about modules in a release to module repository
#
# Takes information about modules in a particular release and builds up
# a "module repository" which contains data about all modules and which
# releases they are included in.
#
# @params $%modrepo	Hash reference of module repository to add to
# @params $%modules	Data as returned from get_release_modules
# @params $release	Version these modules are in (e.g. "3.0.8")
#
# @retval $%modrepo	Hash reference of module repository
#*

sub build_module_repository
{
	my ($modrepo, $modules, $release) = @_;

	# go through all new modules and add to the main module repository
	# as required, tracking release numbers
	#
	foreach my $module (keys %$modules) {
		unless (defined $$modrepo{$module}) {
			$$modrepo{$module} = {
				name => $module,
				minrelease => $release,
				maxrelease => $release,
				list => [],
			};
		}

		my $mrm = $$modrepo{$module};

		push @{$$mrm{list}}, $$modules{$module};

		$$mrm{minrelease} = $release if version_compare($$mrm{minrelease}, $release) > 0;
		$$mrm{maxrelease} = $release if version_compare($$mrm{maxrelease}, $release) < 0;
		if (defined $$mrm{parent} and
			($$mrm{parent} ne $$modules{$module}{parent})) {
			die "differing parents for $module";
		}
		if (defined $$modules{$module}{parent}) {
			$$mrm{parent} = $$modules{$module}{parent};
		}
		if (defined $$modules{$module}{readme}) {
			my $oldversion = $$mrm{readmeversion} || "0.0.0";
			if (version_compare($oldversion, $release) < 0) {
				$$mrm{readme} = $$modules{$module}{readme};
				$$mrm{readmeversion} = $release;
			}
		}
	}

	return $modrepo;
}


# dump things in human-readable form (for now)
#
sub output_module_repository
{
	my $modrepo = shift;

	foreach my $module (sort keys %$modrepo) {
		my $md = $$modrepo{$module};

		print "$module:\n";
		print "\tmin: " . $$md{minrelease} . "\n";
		print "\tmax: " . $$md{maxrelease} . "\n";
		print "\tparent: " . $$md{parent} . "\n" if defined $$md{parent};
		if (defined $$md{readme}) {
			print "\treadme from version: " . $$md{readmeversion} . "\n";
			print "-" x 80 . "\n";
			print $$md{readme};
			print "-" x 80 . "\n";
		}
		print "\n";
	}
}


# get all release tags with version numbers
my $releases = get_releases($repo);

# testing, for now
$$releases{"2.99.99"} = "v2.x.x";
$$releases{"3.0.99"} = "v3.0.x";
$$releases{"4.0.0"} = "v4.0.x";

# module repository
my $modrepo = {};

my $ss = get_release_modules($repo, "v4.0.x");
#print Dumper $ss;

# go through all versions and add the modules to the module repository
foreach my $version (keys %$releases) {
	my $release_modules = get_release_modules($repo, $$releases{$version});
	build_module_repository($modrepo, $release_modules, $version);
}

# dump everything we've got
output_module_repository($modrepo);
