package Archive::Zip::SimpleZip;

use strict;
use warnings;

require 5.006;

use IO::Compress::Zip 2.049 qw(:all);
use IO::Compress::Base::Common  2.049 qw(:Parse createSelfTiedObject whatIsOutput);
use IO::Compress::Adapter::Deflate 2.049 ;

use Fcntl;
use File::Spec;
use IO::File ;
use Carp;
require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $SimpleZipError);

$SimpleZipError= '';
$VERSION = "0.001";

@ISA = qw(Exporter);
@EXPORT_OK = qw( $SimpleZipError ) ;

%EXPORT_TAGS = %IO::Compress::Zip::EXPORT_TAGS ;

Exporter::export_ok_tags('all');


sub _ckParams
{
    my $got = shift || IO::Compress::Base::Parameters::new();
    my $top = shift;
       
    $got->parse(
        {
          
            'Name'          => [0, 1, Parse_any,       ''],
            'Comment'       => [0, 1, Parse_any,       ''],
            'ZipComment'    => [0, 1, Parse_any,       ''],
            'Stream'        => [1, 1, Parse_boolean,   0],
            'Method'        => [0, 1, Parse_unsigned,  ZIP_CM_DEFLATE],
            'Minimal'       => [0, 1, Parse_boolean,   0],
            'Zip64'         => [0, 1, Parse_boolean,   0],
            'FilterName'    => [0, 1, Parse_code,      undef],
            'CanonicalName' => [0, 1, Parse_boolean,   1],
            'TextFlag'      => [0, 1, Parse_boolean,   0],
            'StoreLinks'    => [0, 1, Parse_boolean,   0],
            #'StoreDirs'    => [0, 1, Parse_boolean,   0],
            

            # Zlib
            'Level'         => [0, 1, Parse_signed,    Z_DEFAULT_COMPRESSION],
            'Strategy'      => [0, 1, Parse_signed,    Z_DEFAULT_STRATEGY],

            # Lzma
            'Preset'        => [0, 1, Parse_unsigned, 6],
            'Extreme'       => [1, 1, Parse_boolean,  0],

            
            # Bzip2
            'BlockSize100K' => [0, 1, Parse_unsigned,  1],
            'WorkFactor'    => [0, 1, Parse_unsigned,  0],
            'Verbosity'     => [0, 1, Parse_boolean,   0],
            
        }, 
        @_) or _myDie("Parameter Error: $got->{Error}")  ;

    if ($top)
    {
        for my $opt ( qw(Name Comment) )
        {
            _myDie("$opt option not valid in constructor")  
                if $got->parsed($opt);
        }
                        
        $got->value('CRC32'   => 1);
        $got->value('ADLER32' => 0);
        $got->value('OS_Code' => $Compress::Raw::Zlib::gzip_os_code);
    }
    else
    {
        for my $opt ( qw( ZipComment) )
        {
            _myDie("$opt option only valid in constructor")  
                if $got->parsed($opt);
        }
    }

    return $got;
}

sub _illegalFilename
{
    return _setError(undef, undef, "Illegal Filename") ;
}


#sub simplezip
#{
#    my $from = shift;
#    my $filename = shift ;
#    #my %opts
#
#    my $z = new Archive::Zip::SimpleZip $filename, @_;
#
#    if (ref $from eq 'ARRAY')
#    {
#        $z->add($_) for @$from;
#    }
#    elsif (ref $from)
#    {
#        die "bad";
#    }
#    else
#    {
#        $z->add($filename);
#    }
#
#    $z->close();
#}


sub new
{
    my $class = shift;
    
    $SimpleZipError = '';
    
    return _setError(undef, undef, "Missing Filename") 
        unless @_ ;
       
    my $outValue = shift ;  
    my $fh;
    
    if (!defined $outValue)
    {
        return _illegalFilename
    }

    my $isSTDOUT = ($outValue eq '-') ;
    my $outType = whatIsOutput($outValue);
    
    if ($outType eq 'filename')
    {
        if (-e $outValue && ( ! -f _ || ! -w _))
        {
            return _illegalFilename
        }
        
        $fh = new IO::File ">$outValue"    
            or return _illegalFilename;         
    }
    elsif( $outType eq 'buffer' || $outType eq 'handle')
    {
        $fh = $outValue;
    }
    else
    {
        return _illegalFilename        
    }
    
    my $got = _ckParams(undef, 1, @_);
    $got->value('AutoClose' => 1) unless $outType eq 'handle' ;
    $got->value('Stream' => 1) if $isSTDOUT ;   

    my $obj = {
                ZipFile      => $outValue,
                FH           => $fh,
                Open         => 1,
                FilesWritten => 0,
                Opts         => $got,
                Error        => undef,
                Raw          => 0,                
              };

    bless $obj, $class;
}

sub DESTROY
{
    my $self = shift;
    $self->close();
}

sub close
{
    my $self = shift;
   
    return 0
        if ! $self->{Open} ; 

    $self->{Open} = 0;
    
    if ($self->{FilesWritten})
    {
        defined $self->{Zip} && $self->{Zip}->close()
            or return 0 ;
    }
      
    1;
}

sub _newStream
{
    my $self = shift;
    my $filename = shift ;
    my $options =  shift;
    my %user_options =  @_ ;
    
    while( my ($name, $value) =  each %user_options)
    {
        $options->value($name, $value);
    }

    if (defined $filename)
    {
        IO::Compress::Zip::getFileInfo(undef, $options, $filename) ;
    
        # Force STORE for directories, symbolic links & empty files
        $options->value(Method => ZIP_CM_STORE)  
            if -d $filename || -z _ || -l $filename ;
    }

    # Archive::Zip::SimpleZip handles canonical    
    $options->value(CanonicalName => 0);

    if (! defined $self->{Zip}) {
        $self->{Zip} = createSelfTiedObject('IO::Compress::Zip', \$SimpleZipError);    
        $self->{Zip} ->_create($options, $self->{FH})        
            or die "$SimpleZipError";
    }
    else {
        $self->{Zip}->_newStream($options)
            or die "$SimpleZipError";
    }

    ++ $self->{FilesWritten} ;
    
    return 1;
}


sub _setError
{  
    $SimpleZipError = $_[2] ;
    $_[0]->{Error} = $_[2]
        if defined  $_[0] ;
    
    return $_[1];
}


sub error
{
    my $self = shift;
    return $self->{Error};
}

sub _myDie
{
    $SimpleZipError = $_[0];
    Carp::croak $_[0];

}

sub _stdPreq
{
    my $self = shift;
    
    return 0 
        if $self->{Error} ; 
            
    return $self->_setError(0, "zip file closed") 
        if ! $self->{Open} ;
            
    return $self->_setError(0, "raw mode enabled") 
        if  $self->{Raw};
           
     return 1;    
}

sub add
{
    my $self = shift;
    my $filename = shift;

    $self->_stdPreq or return 0 ;
        
    return $self->_setError(0, "File '$filename' does not exist") 
        if ! -e $filename  ;
        
    return $self->_setError(0, "File '$filename' cannot be read") 
        if ! -r $filename ;        
    
    my $options =  $self->{Opts}->clone();
        
    my $got = _ckParams($options, 0, @_);

    my $isLink = $got->value('StoreLinks') && -l $filename ;
    
    return 0
        if $filename eq '.' || $filename eq '..';
        
    if (! $got->parsed("Name") )
    {
        $got->value("Name", IO::Compress::Zip::canonicalName($filename, -d $filename && ! $isLink));
    }

    $self->_newStream($filename, $got);
    
    if($isLink)
    {
        my $target = readlink($filename);
        $self->{Zip}->write($target);
    }
    elsif (-d $filename)
    {
        # Do nothing, a directory has no payload
    }
    elsif (-f $filename)
    {
        my $fh = new IO::File "<$filename"
            or die "Cannot open file $filename: $!";

        my $data; 
        while ($fh->read($data, 1024 * 16))
        {
            $self->{Zip}->write($data);
        }
    }
    else
    {
        return 0;
    }

    return 1;
}


sub addString
{
    my $self    = shift;
    my $string  = shift;   

    $self->_stdPreq or return 0 ;


    my $options =  $self->{Opts}->clone();
        
    my $got = _ckParams($options, 0, @_);


    $self->_newStream(undef, $got);
    $self->{Zip}->write($string);    
    
    return 1;            
}

1;

__END__

=head1 NAME

Archive::Zip::SimpleZip - Write zip files/buffers

=head1 SYNOPSIS

    use Archive::Zip::SimpleZip qw($SimpleZipError) ;

    my $z = new Archive::Zip::SimpleZip "my.zip"
        or die "Cannot create zip file: $SimpleZipError\n" ;

    $z->add("/some/file1.txt");
    $z->addString("some text", Name => "myfile");

    $z->close();

=head1 DESCRIPTION

Archive::Zip::SimpleZip is a module that allows the creation of Zip archives. 
It doesn't allow modification of existing zip archives - it just writes zip archives from scratch.

There are a few methods available in Archive::Zip::SimpleZip, and quite a few options, 
but for the most part all you need to know is how to create a Zip object 
and how to add a file to the zip archive. 
Below is a typical example of how it is used

    use Archive::Zip::SimpleZip qw($SimpleZipError) ;

    my $z = new Archive::Zip::SimpleZip "my.zip"
        or die "Cannot create zip file: $SimpleZipError\n" ;

    $z->add("/some/file1.txt");
    $z->add("/some/file2.txt");

    $z->close();


=head2 Constructor

     $z = new Archive::Zip::SimpleZip "myzipfile.zip" [, OPTIONS] ;
     $z = new Archive::Zip::SimpleZip \$buffer [, OPTIONS] ;
     $z = new Archive::Zip::SimpleZip $filehandle [, OPTIONS] ;

The constructor takes one mandatory parameter along with zero or more optional patameters.

The mandatory parameter controls where the zip archive is written. 
This can be any of the the following

=over 5

=item * A File

When SimpleZip is passed a string, it will write the zip archive to the filename stored in the string.

=item * A String

When SimpleZip is passed a string reference, it will write the zip archive to the string.

=item * A Filehandle

When SimpleZip is passed a filehandle, it will write the zip archive to that filehandle. 

Use the string '-' to write the zip archive to standard output (Note - this will also enable the C<Stream> option). 


=back

See L</Options> for a list of the optional parameters that can be specified when calling the constructor.

=head2 Methods

=over 5

=item $z->add($filename [, OPTIONS])

The C<add> method writes the contents of the filename stored in C<$filename> to the zip archive.
 

Currenly the module supports these file types.

=over 5

=item * Standard files

The contents of the the file are written to the zip archive. 

=item * Directories

The directory name is stored in the zip archive.

=item * Symbolic Links

By default this module will store the contents of the file that the symbolic link refers to.
It is possible though to store the symbolic link itself by setting the C<StoreLink> option to 1.


=back

By default the name of the entry created in the zip archive will be based on 
the value of the $filename parameter. 
See L</File Naming Options> for more details.  

See L</Options> for a full list of the options available for this method.

Returns 1 if the file was added, or 0. Check the $SimpleZipError for a message.

=item $z->addString($string [, OPTIONS]) 

The addString method writes <$string> to the zip archive.

If none of the L</File Naming Options> are specified, an empty filename will 
created in the zip archive.

See L</Options> for the options available for this method.

Returns 1 if the file was added, or 0. Check the $SimpleZipError for a message.

=item $z->close() 

Returns 1 if the zip archive was closed successfully, or 0. Check the $SimpleZipError for a message.

=back 

=head1 Options

The majority of options are valid in both the constructor and in the methods that 
accept options. Any exceptions are noted in the text below.

Options specified in the constructor will be used as the defaults for all subsequent method call.

For example, in the constructor below, the C<Method> is set to C<ZIP_CM_STORE>. 

    use Archive::Zip::SimpleZip qw($SimpleZipError) ;

    my $z = new Archive::Zip::SimpleZip "my.zip",
                             Method => ZIP_CM_STORE 
        or die "Cannot create zip file: $SimpleZipError\n" ;

    $z->add("file1", Method => ZIP_CM_DEFLATE);
    $z->add("file2");

    $z->close();
   

The first call to C<add> overrides the new default to use C<ZIP_CM_DEFLATE>, while the second
uses the value set in the constructor, C<ZIP_CM_STORE>. 
    

=head2 File Naming Options

These options control how the names of the files are store in the zip archive.

=over 5

=item C<< Name => $string >>

Stores the contents of C<$string> in the zip filename header field. 

When used with the C<add> method, this option will override any filename that
was passed as a parameter.

This option is not valid in the constructor.

=item C<< CanonicalName => 0|1 >>

This option controls whether the filename field in the zip header is
I<normalized> into Unix format before being written to the zip archive.

It is recommended that you keep this option enabled unless you really need
to create a non-standard Zip archive.

This is what APPNOTE.TXT has to say on what should be stored in the zip
filename header field.

    The name of the file, with optional relative path.          
    The path stored should not contain a drive or
    device letter, or a leading slash.  All slashes
    should be forward slashes '/' as opposed to
    backwards slashes '\' for compatibility with Amiga
    and UNIX file systems etc.

This option defaults to B<true>.

=item C<< FilterName => sub { ... }  >>

This option allow the filename field in the zip archive to be modified
before it is written to the zip archive.

This option takes a parameter that must be a reference to a sub.  On entry
to the sub the C<$_> variable will contain the name to be filtered. If no
filename is available C<$_> will contain an empty string.

The value of C<$_> when the sub returns will be  stored in the filename
header field.

Note that if C<CanonicalName> is enabled, a
normalized filename will be passed to the sub.

If you use C<FilterName> to modify the filename, it is your responsibility
to keep the filename in Unix format.

The example below shows how to FilterName can be use to remove the 
path from the filename.

    use Archive::Zip::SimpleZip qw($SimpleZipError) ;

    my $z = new Archive::Zip::SimpleZip "my.zip"
        or die "$SimpleZipError\n" ;

    for ( </some/path/*.c> )
    {
        $z->add($_, FilterName => sub { s[^.*/][] }  ) 
            or die "Cannot add '$_' to zip file: $SimpleZipError\n" ;
    }

    $z->close();


=back

The filename entry stored in a Zip archive is constructed as follows.

The initial source for the filename entry that gets stored in the zip archive is the filename parameter supplied
to the C<add> method. When working with the C<addString> method the filename is an empty string.

Next, if the C<Name> option is supplied that will overide the filename passed to C<add>.

If the C<CanonicalName> option is enabled, and it is by default, the filename gets normalized into Unix format. 
If the filename was absolute, it will be changed into a relative filename.

Finally, is the C<FilterName> option is enabled, the filename will get passed to the sub supplied via the C<$_> variable. 
The value of C<$_> on exit from the sub will get stored in the zip archive.

Here are some examples

    use Archive::Zip::SimpleZip qw($SimpleZipError) ;

    my $z = new Archive::Zip::SimpleZip "my.zip"
        or die "$SimpleZipError\n" ;

    # store "my/abc.txt" in the zip archive
    $z->add("/my/abc.txt") ;

    # store "/my/abc.txt" in the zip archive
    $z->add("/my/abc.txt", CanonoicalName => 0) ;
    
    # store "xyz" in the zip archive
    $z->add("/some/file", Name => "xyz") ;
 
    # store "file3.txt" in the zip archive
    $z->add("/my/file3.txt", FilterName => sub { s#.*/## } ) ;
        
    # store "" in the zip archive
    $z->addString("payload data") ;
            
    # store "xyz" in the zip archive
    $z->addString("payload data", Name => "xyz") ;
                        
    # store "/abc/def" in the zip archive
    $z->addString("payload data", Name => "/abc/def", CanonoicalName => 0) ;
                    
    $z->close(); 
  

=head2 Overall Zip Archive Structure



=over 5

=item C<< Minimal => 1|0 >>

If specified, this option will disable the creation of all extra fields
in the zip local and central headers. 

This option is useful when interoperability with an old version of unzip is an issue. TODO - more here.

This parameter defaults to 0.

=item C<< Stream => 0|1 >>

This option controls whether the zip farchive is created in
streaming mode.

Note that when outputting to a file or filehandle with streaming mode disabled (C<Stream>
is 0), the output file/handle must be seekable.

When outputting to '-' (STDOUT) Stream is automatically enabled.

TODO - when to use & interoperability issues.

The default is 0.

=item C<< Zip64 => 0|1 >>

ZIP64 is an extension to the Zip archive structure that allows 

=over 5

=item * Zip archives larger than 4Gig.

=item * Zip archives with more that 64K members.

=back

The module will automatically enable ZIP64 mode as needed when creating zip archive.  

You can force creation of a Zip64 zip archive by enabling this option.

If you intend to manipulate the Zip64 zip archives created with this module
using an external zip/unzip program/library, make sure that it supports Zip64.   

The default is 0.

=back

=head2 Other Options

=over 5

=item C<< Comment => $comment >>

This option allows the creation of a comment that is associated with the
entry added to the zip archive with the C<add> and C<addString> methods. 

This option is not valid in the constructor.

By default, no comment field is written to the zip archive.


=item C<< Method => $method >>

Controls which compression method is used. At present four compression
methods are supported, namely Store (no compression at all), Deflate, 
Bzip2 and Lzma.

The symbols, ZIP_CM_STORE, ZIP_CM_DEFLATE, ZIP_CM_BZIP2 and ZIP_CM_LZMA 
are used to select the compression method.

These constants are not imported by default by this module.

    use Archive::Zip::SimpleZip qw(:zip_method);
    use Archive::Zip::SimpleZip qw(:constants);
    use Archive::Zip::SimpleZip qw(:all);

Note that to create Bzip2 content, the module C<IO::Compress::Bzip2> must
be installed. A fatal error will be thrown if you attempt to create Bzip2
content when C<IO::Compress::Bzip2> is not available.

Note that to create Lzma content, the module C<IO::Compress::Lzma> must
be installed. A fatal error will be thrown if you attempt to create Lzma
content when C<IO::Compress::Lzma> is not available.

The default method is ZIP_CM_DEFLATE for files and ZIP_CM_STORE for directories and symbolic links.



=item C<< StoreLink => 1|0  >>

Controls what C<Archive::Zip::SimpleZip> does with a symbolic link.

When true, it stores the link itself.
When false, it stores the contents of the file the link refers to.

If your platform does not support symbolic links this option is ignored.

Default is 0.



=item C<< TextFlag => 0|1 >>

This parameter controls the setting of a flag in the zip central header. It
is used to signal that the data stored in the zip archive is probably
text.

The default is 0. 
        

=item C<< ZipComment => $comment >>

This option allows the creation of a comment field for the entire zip archive.

This option is only valid in the constructor.

By default, no comment field is written to the zip archive.


=back
 

=head2 Deflate Compression Options

These option are only valid if the C<Method> is ZIP_CM_DEFLATE. They are ignored
otherwise.

=over 5

=item C<< Level => value >> 

Defines the compression level used by zlib. The value should either be
a number between 0 and 9 (0 means no compression and 9 is maximum
compression), or one of the symbolic constants defined below.

   Z_NO_COMPRESSION
   Z_BEST_SPEED
   Z_BEST_COMPRESSION
   Z_DEFAULT_COMPRESSION

The default is Z_DEFAULT_COMPRESSION.

=item C<< Strategy => value >> 

Defines the strategy used to tune the compression. Use one of the symbolic
constants defined below.

   Z_FILTERED
   Z_HUFFMAN_ONLY
   Z_RLE
   Z_FIXED
   Z_DEFAULT_STRATEGY

The default is Z_DEFAULT_STRATEGY.

=back  
        

=head2 Bzip2 Compression Options

These option are only valid if the C<Method> is ZIP_CM_BZIP2. They are ignored
otherwise.

=over 5

=item C<< BlockSize100K => number >>

Specify the number of 100K blocks bzip2 uses during compression. 

Valid values are from 1 to 9, where 9 is best compression.

The default is 1.

=item C<< WorkFactor => number >>

Specifies how much effort bzip2 should take before resorting to a slower
fallback compression algorithm.

Valid values range from 0 to 250, where 0 means use the default value 30.


The default is 0.

=back

=head2 Lzma Compression Options

These option are only valid if the C<Method> is ZIP_CM_LZMA. They are ignored
otherwise.

=over 5

=item C<< Preset => number >>

Used to choose the LZMA compression preset.

Valid values are 0-9 and C<LZMA_PRESET_DEFAULT>.

0 is the fastest compression with the lowest memory usage and the lowest
compression.

9 is the slowest compession with the highest memory usage but with the best
compression.

Defaults to C<LZMA_PRESET_DEFAULT> (6).

=item C<< Extreme => 0|1 >>

Makes LZMA compression a lot slower, but a small compression gain.

Defaults to 0.


=back

=head1 Summary of Default Behaviour

By default C<Archive::Zip::SimpleZip> will  do the following

=over 5

=item * Use Deflate Compression for all non-directories.

=item * Create a non-streamed Zip archive

=item * Follow Symbolic Links

=item * Canonicalise the filename before adding it to the zip archive

=item * Only use create a ZIP64 Zip archive if any of the input files is greater than 4 Gig or there are more than 64K members in the zip archive.

=item * Fill out the following zip extended attributes

    "UT" Extended Timestamp
    "ux" ExtraExtra Type 3 (if running Unix)
    

=back
  

You can change the behaviour of most of the features mentioned above.

=head1 Examples

=head2 A Simple example

Add all the "C" files in the current directory to the zip archive "my.zip".

    use Archive::Zip::SimpleZip qw($SimpleZipError) ;

    my $z = new Archive::Zip::SimpleZip "my.zip"
        or die "$SimpleZipError\n" ;

    for ( <*.c> )
    {
        $z->add($_) 
            or die "Cannot add '$_' to zip file: $SimpleZipError\n" ;
    }

    $z->close();


=head2 Rename whilst adding

TODO

=head2 Working with File::Find 

TODO

=head2 Writing a zip archive to a socket

TODO

=head1 Importing 

A number of symbolic constants are required by some methods in 
C<Archive::Zip::SimpleZip>. None are imported by default.

=over 5

=item :all

Imports C<zip>, C<$SimpleZipError> and all symbolic
constants that can be used by C<IArchive::Zip::SimpleZip>. Same as doing this

    use Archive::Zip::SimpleZip qw(zip $SimpleZipError :constants) ;

=item :constants

Import all symbolic constants. Same as doing this

    use Archive::Zip::SimpleZip qw(:flush :level :strategy :zip_method) ;

=item :flush

These symbolic constants are used by the C<flush> method.

    Z_NO_FLUSH
    Z_PARTIAL_FLUSH
    Z_SYNC_FLUSH
    Z_FULL_FLUSH
    Z_FINISH
    Z_BLOCK

=item :level

These symbolic constants are used by the C<Level> option in the constructor.

    Z_NO_COMPRESSION
    Z_BEST_SPEED
    Z_BEST_COMPRESSION
    Z_DEFAULT_COMPRESSION

=item :strategy

These symbolic constants are used by the C<Strategy> option in the constructor.

    Z_FILTERED
    Z_HUFFMAN_ONLY
    Z_RLE
    Z_FIXED
    Z_DEFAULT_STRATEGY

=item :zip_method

These symbolic constants are used by the C<Method> option in the
constructor.

    ZIP_CM_STORE
    ZIP_CM_DEFLATE
    ZIP_CM_BZIP2

=back

=head1 SEE ALSO


L<IO::Compress::Zip>, L<Archive::Zip>, L<IO::Uncompress::UnZip>


=head1 AUTHOR

This module was written by Paul Marquess, F<pmqs@cpan.org>. 

=head1 MODIFICATION HISTORY

See the Changes file.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012 Paul Marquess. All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

    
    