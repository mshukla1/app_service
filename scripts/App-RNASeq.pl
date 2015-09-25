#
# The RNASeq Analysis application.
#

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use JSON;

use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

my $data_url = Bio::KBase::AppService::AppConfig->data_api_url;
# my $data_url = "http://www.alpha.patricbrc.org/api";

my $script = Bio::KBase::AppService::AppScript->new(\&process_rnaseq);
my $rc = $script->run(\@ARGV);
exit $rc;

# use JSON;
# my $temp_params = JSON::decode_json(`cat /home/fangfang/P3/dev_container/modules/app_service/test_data/rna.inp`);
# process_rnaseq('RNASeq', undef, undef, $temp_params);

our $global_ws;
our $global_token;

sub process_rnaseq {
    my ($app, $app_def, $raw_params, $params) = @_;

    print "Proc RNASeq ", Dumper($app_def, $raw_params, $params);

    $global_token = $app->token();
    $global_ws = $app->workspace;

    my $output_folder = $app->result_folder();
    # my $output_base   = $params->{output_file};

    my $recipe = $params->{recipe};

    my $tmpdir = File::Temp->newdir();
    # my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
    # my $tmpdir = "/tmp/nxmyAFcE2a";
    # my $tmpdir = "/tmp/ZKLUBOtpuf";
    # my $tmpdir = "/tmp/_jfhupHJs8";
    system("chmod 755 $tmpdir");
    print STDERR "$tmpdir\n";
    $params = localize_params($tmpdir, $params);

    my @outputs;
    my $prefix = $recipe;
    if ($recipe eq 'Rockhopper') {
        @outputs = run_rockhopper($params, $tmpdir);
    } elsif ($recipe eq 'Tuxedo' || $recipe eq 'RNA-Rocket') {
        @outputs = run_rna_rocket($params, $tmpdir);
        $prefix = 'Tuxedo';
    } else {
        die "Unrecognized recipe: $recipe \n";
    }

    print STDERR '\@outputs = '. Dumper(\@outputs);
    for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$prefix\_$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$prefix\_$filename", $type, 1,
					       (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       # (-s "$ofile" > 20_000_000 ? 1 : 0), # use shock for larger files
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }

}

sub run_rna_rocket {
    my ($params, $tmpdir) = @_;

    my $exps     = params_to_exps($params);
    my $labels   = $params->{experimental_conditions};
    my $ref_id   = $params->{reference_genome_id} or die "Reference genome is required for RNA-Rocket\n";
    my $ref_dir  = prepare_ref_data_rocket($ref_id, $tmpdir);

    print "Run rna_rocket ", Dumper($exps, $labels, $tmpdir);

    # my $rocket = "/home/fangfang/programs/Prok-tuxedo/prok_tuxedo.py";
    my $rocket = "prok_tuxedo.py";
    verify_cmd($rocket);

    my $outdir = "$tmpdir/Rocket";

    my @cmd = ($rocket);
    push @cmd, ("-o", $outdir);
    push @cmd, ("-g", $ref_dir);
    push @cmd, ("-L", join(",", map { s/^\W+//; s/\W+$//; s/\W+/_/g; $_ } @$labels)) if $labels && @$labels;
    push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;

    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";

    my ($rc, $out, $err) = run_cmd(\@cmd);
    print STDERR "STDOUT:\n$out\n";
    print STDERR "STDERR:\n$err\n";

    run("echo $outdir && ls -ltr $outdir");

    my @files = glob("$outdir/$ref_id/*diff $outdir/$ref_id/*/replicate*/*_tracking $outdir/$ref_id/*/replicate*/*.gtf $outdir/$ref_id/*/replicate*/*.bam");
    print STDERR '\@files = '. Dumper(\@files);
    my @new_files;
    for (@files) {
        if (m|/\S*?/replicate\d/|) {
            my $fname = $_; $fname =~ s|/(\S*?)/(replicate\d)/|/$1\_$2\_|;
            run_cmd(["mv", $_, $fname]);
            push @new_files, $fname;
        } else {
            push @new_files, $_;
        }
    }
    my @outputs = map { /\.bam$/ ? [ $_, 'bam' ] : [ $_, 'txt' ] } @new_files;

    push @outputs, [ "$outdir/$ref_id/gene_exp.gmx", 'diffexp_input_data' ] if -s "$outdir/$ref_id/gene_exp.gmx";

    return @outputs;
}

sub run_rockhopper {
    my ($params, $tmpdir) = @_;

    my $exps     = params_to_exps($params);
    my $labels   = $params->{experimental_conditions};
    my $stranded = defined($params->{strand_specific}) && !$params->{strand_specific} ? 0 : 1;
    my $ref_id   = $params->{reference_genome_id};
    my $ref_dir  = prepare_ref_data($ref_id, $tmpdir) if $ref_id;

    print "Run rockhopper ", Dumper($exps, $labels, $tmpdir);

    # my $jar = "/home/fangfang/programs/Rockhopper.jar";
    my $jar = $ENV{KB_RUNTIME} . "/lib/Rockhopper.jar";
    -s $jar or die "Could not find Rockhopper: $jar\n";

    my $outdir = "$tmpdir/Rockhopper";

    my @cmd = (qw(java -Xmx1200m -cp), $jar, "Rockhopper");

    print STDERR '$exps = '. Dumper($exps);

    my @conditions = clean_labels($labels);

    push @cmd, qw(-SAM -TIME);
    push @cmd, qw(-s false) unless $stranded;
    push @cmd, ("-p", 1);
    push @cmd, ("-o", $outdir);
    push @cmd, ("-g", $ref_dir) if $ref_dir;
    push @cmd, ("-L", join(",", @conditions)) if $labels && @$labels;
    push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;

    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";

    my ($rc, $out, $err) = run_cmd(\@cmd);
    print STDERR "STDOUT:\n$out\n";
    print STDERR "STDERR:\n$err\n";

    run("echo $outdir && ls -ltr $outdir");

    my @outputs;
    if ($ref_id) {
        @outputs = merge_rockhoppper_results($outdir, $ref_id, $ref_dir);
        my $gmx = make_diff_exp_gene_matrix($outdir, $ref_id, \@conditions);
        push @outputs, [ $gmx, 'diffexp_input_data' ] if -s $gmx;
    } else {
        my @files = glob("$outdir/*.txt");
        @outputs = map { [ $_, 'txt' ] } @files;
    }

    return @outputs;
}

sub make_diff_exp_gene_matrix {
    my ($dir, $ref_id, $conditions) = @_;

    my $transcript = "$dir/$ref_id\_transcripts.txt";
    my $num = scalar@$conditions;
    return unless -s $transcript && $num > 1;

    my @genes;
    my %hash;
    my @comps;

    my @lines = `cat $transcript`;
    shift @lines;
    my $comps_built;
    for (@lines) {
        my @cols = split /\t/;
        my $gene = $cols[6]; next unless $gene =~ /\w/;
        my @exps = @cols[9..8+$num];
        # print join("\t", $gene, @exps) . "\n";
        push @genes, $gene;
        for (my $i = 0; $i < @exps; $i++) {
            for (my $j = $i+1; $j < @exps; $j++) {
                my $ratio = log_ratio($exps[$i], $exps[$j]);
                my $comp = comparison_name($conditions->[$i], $conditions->[$j]);
                $hash{$gene}->{$comp} = $ratio;
                push @comps, $comp unless $comps_built;
            }
        }
        $comps_built = 1;
    }

    my $outf = "$dir/$ref_id\_gene_exp.gmx";
    my @outlines;
    push @outlines, join("\t", 'Gene ID', @comps);
    for my $gene (@genes) {
        my $line = $gene;
        $line .= "\t".$hash{$gene}->{$_} for @comps;
        push @outlines, $line;
    }
    my $out = join("\n", @outlines)."\n";
    write_output($out, $outf);

    return $outf;
}

sub log_ratio {
    my ($exp1, $exp2) = @_;
    $exp1 = 0.01 if $exp1 < 0.01;
    $exp2 = 0.01 if $exp2 < 0.01;
    return sprintf("%.3f", log($exp2/$exp1) / log(2));
}

sub comparison_name {
    my ($cond1, $cond2) = @_;
    return join('|', $cond2, $cond1);
}

sub clean_labels {
    my ($labels) = @_;
    return undef unless $labels && @$labels;
    return map { s/^\W+//; s/\W+$//; s/\W+/_/g; $_ } @$labels;
}

sub merge_rockhoppper_results {
    my ($dir, $gid, $ref_dir_str) = @_;
    my @outputs;

    my @ref_dirs = split(/,/, $ref_dir_str);
    my @ctgs = map { s/.*\///; $_ } @ref_dirs;

    my %types = ( "transcripts.txt" => 'txt',
                  "operons.txt"     => 'txt' );

    for my $result (keys %types) {
        my $type = $types{$result};
        my $outf = join("_", "$dir/$gid", $result);
        my $out;
        for my $ctg (@ctgs) {
            my $f = join("_", "$dir/$ctg", $result);
            my @lines = `cat $f`;
            my $hdr = shift @lines;
            $out ||= join("\t", 'Contig', $hdr);
            $out  .= join('', map { join("\t", $ctg, $_ ) } grep { /\S/ } @lines);
        }
        write_output($out, $outf);
        push @outputs, [ $outf, $type ];
    }

    my @sams = glob("$dir/*.sam");
    for my $f (@sams) {
        my $sam = basename($f);
        my $bam = $sam;
        $bam =~ s/_R[12]\.sam$/.sam/;
        $bam =~ s/\.sam$/.bam/;
        $bam = "$dir/$bam";
        my @cmd = ("samtools", "view", "-bS", $f, "-o", $bam);
        run_cmd(\@cmd);
        push @outputs, [ $bam, 'bam' ];
    }
    push @outputs, ["$dir/summary.txt", 'txt'];

    return @outputs;
}

sub prepare_ref_data_rocket {
    my ($gid, $basedir) = @_;
    $gid or die "Missing reference genome id\n";

    my $dir = "$basedir/$gid";
    system("mkdir -p $dir");

    my $api_url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,CDS),eq(feature_type,tRNA),eq(feature_type,rRNA)))&sort(+accession,+start,+end)&http_accept=application/cufflinks+gff&limit(25000)";
    my $ftp_url = "ftp://ftp.patricbrc.org/patric2/patric3/genomes/$gid/$gid.PATRIC.gff";

    my $url = $api_url;
    # my $url = $ftp_url;
    my $out = curl_text($url);
    write_output($out, "$dir/$gid.gff");

    $api_url = "$data_url/genome_sequence/?eq(genome_id,$gid)&http_accept=application/dna+fasta&limit(25000)";
    $ftp_url = "ftp://ftp.patricbrc.org/patric2/patric3/genomes/$gid/$gid.fna";

    $url = $api_url;
    # $url = $ftp_url;
    my $out = curl_text($url);
    # $out = break_fasta_lines($out."\n");
    $out =~ s/\n+/\n/g;
    write_output($out, "$dir/$gid.fna");

    return $dir;
}

sub prepare_ref_data {
    my ($gid, $basedir) = @_;
    $gid or die "Missing reference genome id\n";

    my $url = "$data_url/genome_sequence/?eq(genome_id,$gid)&select(accession,genome_name,description,length,sequence)&sort(+accession)&http_accept=application/json&limit(25000)";
    my $json = curl_json($url);
    # print STDERR '$json = '. Dumper($json);
    my @ctgs = map { $_->{accession} } @$json;
    my %hash = map { $_->{accession} => $_ } @$json;

    $url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),eq(feature_type,CDS))&select(accession,start,end,strand,aa_length,patric_id,protein_id,gene,refseq_locus_tag,figfam_id,product)&sort(+accession,+start,+end)&limit(25000)&http_accept=application/json";
    $json = curl_json($url);

    for (@$json) {
        my $ctg = $_->{accession};
        push @{$hash{$ctg}->{cds}}, $_;
    }

    $url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,tRNA),eq(feature_type,rRNA)))&select(accession,start,end,strand,na_length,patric_id,protein_id,gene,refseq_locus_tag,figfam_id,product)&sort(+accession,+start,+end)&limit(25000)&http_accept=application/json";
    $json = curl_json($url);

    for (@$json) {
        my $ctg = $_->{accession};
        push @{$hash{$ctg}->{rna}}, $_;
    }

    my @dirs;
    for my $ctg (@ctgs) {
        my $dir = "$basedir/$gid/$ctg";
        system("mkdir -p $dir");
        my $ent = $hash{$ctg};
        my $cds = $ent->{cds};
        my $rna = $ent->{rna};

        # Rockhopper only parses FASTA header of the form: >xxx|xxx|xxx|xxx|ID|
        my $fna = join("\n", ">genome|$gid|accn|$ctg|   $ent->{description}   [$ent->{genome_name}]",
                       uc($ent->{sequence}) =~ m/.{1,60}/g)."\n";

        my $ptt = join("\n", "$ent->{description} - 1..$ent->{length}",
                             scalar@{$ent->{cds}}.' proteins',
                             join("\t", qw(Location Strand Length PID Gene Synonym Code FIGfam Product)),
                             map { join("\t", $_->{start}."..".$_->{end},
                                              $_->{strand},
                                              $_->{aa_length},
                                              $_->{patric_id} || $_->{protein_id},
                                              # $_->{refseq_locus_tag},
                                              $_->{patric_id},
                                              # $_->{gene},
                                              join("/", $_->{refseq_locus_tag}, $_->{gene}),
                                              '-',
                                              $_->{figfam_id},
                                              $_->{product})
                                            } @$cds
                      ) if $cds && @$cds;

        my $rnt = join("\n", "$ent->{description} - 1..$ent->{length}",
                             scalar@{$ent->{rna}}.' RNAs',
                             join("\t", qw(Location Strand Length PID Gene Synonym Code FIGfam Product)),
                             map { join("\t", $_->{start}."..".$_->{end},
                                              $_->{strand},
                                              $_->{na_length},
                                              $_->{patric_id} || $_->{protein_id},
                                              # $_->{refseq_locus_tag},
                                              $_->{patric_id},
                                              # $_->{gene},
                                              join("/", $_->{refseq_locus_tag}, $_->{gene}),
                                              '-',
                                              $_->{figfam_id},
                                              $_->{product})
                                            } @$rna
                      ) if $rna && @$rna;

        write_output($fna, "$dir/$ctg.fna");
        write_output($ptt, "$dir/$ctg.ptt") if $ptt;
        write_output($rnt, "$dir/$ctg.rnt") if $rnt;

        push(@dirs, $dir) if $ptt;
    }

    return join(",",@dirs);
}

sub curl_text {
    my ($url) = @_;
    my @cmd = ("curl", curl_options(), $url);
    print STDERR join(" ", @cmd)."\n";
    my ($out) = run_cmd(\@cmd);
    return $out;
}

sub curl_json {
    my ($url) = @_;
    my $out = curl_text($url);
    my $hash = JSON::decode_json($out);
    return $hash;
}

sub curl_options {
    my @opts;
    my $token = get_token()->token;
    push(@opts, "-H", "Authorization: $token");
    push(@opts, "-H", "Content-Type: multipart/form-data");
    return @opts;
}

sub run_cmd {
    my ($cmd) = @_;
    my ($out, $err);
    run($cmd, '>', \$out, '2>', \$err)
        or die "Error running cmd=@$cmd, stdout:\n$out\nstderr:\n$err\n";
    # print STDERR "STDOUT:\n$out\n";
    # print STDERR "STDERR:\n$err\n";
    return ($out, $err);
}

sub params_to_exps {
    my ($params) = @_;
    my @exps;
    for (@{$params->{paired_end_libs}}) {
        my $index = $_->{condition} - 1;
        $index = 0 if $index < 0;
        push @{$exps[$index]}, [ $_->{read1}, $_->{read2} ];
    }
    for (@{$params->{single_end_libs}}) {
        my $index = $_->{condition} - 1;
        $index = 0 if $index < 0;
        push @{$exps[$index]}, [ $_->{read} ];
    }
    return \@exps;
}

sub localize_params {
    my ($tmpdir, $params) = @_;
    for (@{$params->{paired_end_libs}}) {
        $_->{read1} = get_ws_file($tmpdir, $_->{read1}) if $_->{read1};
        $_->{read2} = get_ws_file($tmpdir, $_->{read2}) if $_->{read2};
    }
    for (@{$params->{single_end_libs}}) {
        $_->{read} = get_ws_file($tmpdir, $_->{read}) if $_->{read};
    }
    return $params;
}


sub get_ws {
    return $global_ws;
}

sub get_token {
    return $global_token;
}

sub get_ws_file {
    my ($tmpdir, $id) = @_;
    # return $id; # DEBUG
    my $ws = get_ws();
    my $token = get_token();

    my $base = basename($id);
    my $file = "$tmpdir/$base";
    # return $file; # DEBUG

    my $fh;
    open($fh, ">", $file) or die "Cannot open $file for writing: $!";

    print STDERR "GET WS => $tmpdir $base $id\n";
    system("ls -la $tmpdir");

    eval {
	$ws->copy_files_to_handles(1, $token, [[$id, $fh]]);
    };
    if ($@)
    {
	die "ERROR getting file $id\n$@\n";
    }
    close($fh);
    print "$id $file:\n";
    system("ls -la $tmpdir");

    return $file;
}

sub write_output {
    my ($string, $ofile) = @_;
    open(F, ">$ofile") or die "Could not open $ofile";
    print F $string;
    close(F);
}

sub break_fasta_lines {
    my ($fasta) = @_;
    my @lines = split(/\n/, $fasta);
    my @fa;
    for (@lines) {
        if (/^>/) {
            push @fa, $_;
        } else {
            push @fa, /.{1,60}/g;
        }
    }
    return join("\n", @fa);
}

sub verify_cmd {
    my ($cmd) = @_;
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}
