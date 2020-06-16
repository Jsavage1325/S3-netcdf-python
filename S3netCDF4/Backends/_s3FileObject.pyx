#!python
#cython: language_level=3
__copyright__ = "(C) 2019 Science and Technology Facilities Council"
__license__ = "BSD - see LICENSE file in top-level directory"

import io
import fnmatch
from urllib.parse import urlparse, urljoin, urlsplit

from botocore.exceptions import ClientError
import botocore.session

from S3netCDF4.Managers._ConnectionPool import ConnectionPool
from S3netCDF4.Managers._ConfigManager import Config
from S3netCDF4._Exceptions import APIException, IOException

class s3FileObject(io.BufferedIOBase):
    """Custom file object class, inheriting from Python io.Base, to read from
    an S3 object store / AWS cloud storage."""

    """Static connection pool object - i.e. shared across the file objects."""
    _connection_pool = ConnectionPool()

    # The defaults for MAXIMUM_PART_SIZE etc. are now assigned in
    # __init__ if no values are found in ~/.s3nc.json
    """Static config object for the backend options"""
    _config = Config()

    def _get_server_bucket_object(uri):
        """Get the server name from the URI"""
        # First split the uri into the network location and path, and build the
        # server
        url_p = urlparse(uri)
        # check that the uri contains a scheme and a netloc
        if url_p.scheme == '' or url_p.netloc == '':
            raise APIException(
                "URI supplied to s3FileObject is not well-formed: {}".format(uri)
            )
        server = url_p.scheme + "://" + url_p.netloc
        split_path = url_p.path.split("/")
        # get the bucket
        try:
            bucket = split_path[1]
        except IndexError as e:
            raise APIException(
                "URI supplied has no bucket contained within it: {}".format(uri)
            )
        # get the path
        try:
            path = "/".join(split_path[2:])
        except IndexError as e:
            raise APIException(
                "URI supplied has no path contained within it: {}".format(uri)
            )
        return server, bucket, path

    def __init__(self, uri, credentials, mode='r', create_bucket=True,
                 part_size=None, max_parts=None, multipart_upload=None,
                 multipart_download=None, connect_timeout=None,
                 read_timeout=None):
        """Initialise the file object by creating or reusing a connection in the
        connection pool."""
        # get the server, bucket and the key from the endpoint url
        self._server, self._bucket, self._path = s3FileObject._get_server_bucket_object(uri)
        self._closed = False            # set the file to be not closed
        self._mode = mode
        self._seek_pos = 0
        self._buffer = [io.BytesIO()]   # have a list of objects that can stream
        self._credentials = credentials
        self._create_bucket = create_bucket
        self._uri = uri

        """Either get the backend config from the parameters, or the config file
        or use defaults."""
        if "s3FileObject" in s3FileObject._config["backends"]:
            backend_config = s3FileObject._config["backends"]["s3FileObject"]
        else:
            backend_config = {}

        if part_size:
            self._part_size = part_size
        elif "maximum_part_size" in backend_config:
            self._part_size = backend_config["maximum_part_size"]
        else:
            self._part_size = 50 * 1024 * 1024

        if max_parts:
            self._max_parts = max_parts
        elif "maximum_parts" in backend_config:
            self._max_parts = backend_config["maximum_parts"]
        else:
            self._max_parts = 8

        if multipart_upload:
            self._multipart_upload = multipart_upload
        elif "multipart_upload" in backend_config:
            self._multipart_upload = backend_config["multipart_upload"]
        else:
            self._multipart_upload = True

        if multipart_download:
            self._multipart_download = multipart_download
        elif "multipart_download" in backend_config:
            self._multipart_download = backend_config["multipart_download"]
        else:
            self._multipart_download = True

        if connect_timeout:
            self._connect_timeout = connect_timeout
        elif "connect_timeout" in backend_config:
            self._connect_timeout = backend_config["connect_timeout"]
        else:
            self._connect_timeout = 30.0

        if read_timeout:
            self._read_timeout = read_timeout
        elif "read_timeout" in backend_config:
            self._read_timeout = backend_config["read_timeout"]
        else:
            self._read_timeout = 30.0

    def __enter__(self):
        """Create the connection on an enter."""
        self.connect()
        return self

    def __exit__(self, exc_type, exc_value, exc_tb):
        """Close the file on the exit of a with statement, or by the garbage
        collector removing the object."""
        self.close()
        # check for any exceptions
        if exc_type is not None:
            return False
        return True

    def _getsize(self):
        # Use content length in the head object to determine the size of
        # the file / object
        # If we are writing then the size should be the buffer size
        try:
            if 'w' in self._mode:
                size = self._part_size
            else:
                response = self._conn_obj.conn.head_object(
                    Bucket=self._bucket,
                    Key=self._path
                )
                size = response['ContentLength']
        except ClientError as e:
            raise IOException(
                "Could not get size of object {}".format(self._path)
            )
        except AttributeError as e:
            self._handle_connection_exception(e)
        return size

    def _get_bucket_list(self):
        # get the names of the buckets in a list
        try:
            bl = self._conn_obj.conn.list_buckets()['Buckets'] # this returns a dict
            bucket_list = [b['Name'] for b in bl]
        except AttributeError as e:
            self._handle_connection_exception(e)
        return bucket_list

    def _handle_connection_exception(self, e):
        # Check if connection made
        if ("_conn_obj" in e.args[0] or "_current_part" in e.args[0]):
            raise APIException(
                "Connection to S3 server is not established.  Use either the "
                ".connect method or a with statement."
            )
        else:
            # other AttributeError - handle that separately
            raise e

    def connect(self):
        """Connect to the s3 server with the details passed in via the __init__
        method."""
        # if the connection returns None then either there isn't a connection to
        # the server in the pool, or there is no connection that is available
        self._conn_obj = s3FileObject._connection_pool.get(self._server)
        if self._conn_obj is None:
            try:
                session = botocore.session.get_session()
                config = botocore.config.Config(
                    connect_timeout=self._connect_timeout,
                    read_timeout=self._connect_timeout
                )
                s3c = session.create_client(
                          "s3",
                          endpoint_url=self._server,
                          aws_access_key_id=self._credentials["accessKey"],
                          aws_secret_access_key=self._credentials["secretKey"],
                          config=config
                      )
                # add the connection to the connection pool
                self._conn_obj = s3FileObject._connection_pool.add(
                    s3c, self._server
                )
            except ClientError as e:
                raise IOException(
                    "Could not connect to S3 endpoint {} {}".format(
                        self._server, e)
                )
        if ('r' in self._mode and '*' not in self._path and
            '?' not in self._path):
            # if this is a read method then check the file exists
            response = self._conn_obj.conn.list_objects_v2(
                Bucket=self._bucket,
                Prefix=self._path
            )
            exists = False
            for obj in response.get('Contents', []):
                if obj['Key'] == self._path:
                    exists = True
                    break
            if not exists:
                raise IOException(
                    "Object does not exist: {}/{}/{}".format(
                        self._server, self._bucket, self._path
                    )
                )
        if 'w' in self._mode:
            # if this is a write method then create a bytes array
            self._current_part = 1
        if 'a' in self._mode or '+' in self._mode:
            raise APIException(
                "Appending to files is not supported {}".format(self._path)
            )
        return True

    def detach(self):
        """Separate the underlying raw stream from the buffer and return it.
        Not supported in S3."""
        raise io.UnsupportedOperation

    def read(self, size=-1):
        """Read and return up to size bytes. For the S3 implementation the size
        can be used for RangeGet.  If size==-1 then the whole object is streamed
        into memory."""
        # read the object using the bucket and path already determined in
        # __init__, and using the connection object
        try:
            if size== -1:
                s3_object = self._conn_obj.conn.get_object(
                    Bucket = self._bucket,
                    Key = self._path
                )
                body = s3_object['Body']
            else:
                # do the partial / range get version, and increment the seek
                # pointer
                range_end = self._seek_pos+size-1
                file_size = self._getsize()
                if range_end >= file_size:
                    range_end = file_size-1

                if not self._multipart_download:
                    s3_object = self._conn_obj.conn.get_object(
                        Bucket = self._bucket,
                        Key = self._path,
                    )
                    body = s3_object['Body']
                else:
                    s3_object = self._conn_obj.conn.get_object(
                        Bucket = self._bucket,
                        Key = self._path,
                        Range = 'bytes={}-{}'.format(
                            self._seek_pos, range_end
                        )
                    )
                    self._seek_pos += size
                    body = s3_object['Body']
        except ClientError as e:
            raise IOException(
                "Could not read from object {} {}".format(self._path, e)
            )
        except AttributeError as e:
            self._handle_connection_exception(e)
        return body.read()

    def read1(self, size=-1):
        """Just call read."""
        return self.read(size=size)

    def readinto(self, b):
        """Read bytes into a pre-allocated, writable bytes-like object b and
        return the number of bytes read.
        In S3 the entire file is read into the bytesbuffer.  It is important
        that the bytesbuffer is big enough to hold the entire file."""
        # get the size of the file
        size = self._getsize()
        b[:size] = self.read(size)
        return size

    def readinto1(self, b):
        """Just call readinto"""
        return self.readinto(b)

    def _multipart_upload_from_buffer(self):
        """Do a multipart upload from the buffer.
        There are two cases:
            1.  The size is exactly the same size as the self._part_size
            2.  The size is greater than the self._part_size
        """
        # check to see if bucket needs to be created
        if self._create_bucket:
            # check whether the bucket exists
            bucket_list = self._get_bucket_list()
            if not self._bucket in bucket_list:
                self._conn_obj.conn.create_bucket(Bucket=self._bucket)

        # if the current part is 1 we have to create the multipart upload
        if self._current_part == 1:
            response = self._conn_obj.conn.create_multipart_upload(
                Bucket = self._bucket,
                Key = self._path
            )
            self._upload_id = response['UploadId']
            # we need to keep a track of the multipart info
            self._multipart_info = {'Parts' : []}

        # upload from a buffer - do we need to split into more than one
        # multiparts?  Remember: self._buffer is a list of BytesIO objects
        new_buffer = []
        for buffer_part in range(0, len(self._buffer)):
            # is the current part of the buffer larger than the maximum
            # upload size? split if it is
            data_buf = self._buffer[buffer_part]
            data_len = data_buf.tell()
            if data_len >= s3FileObject.MAXIMUM_PART_SIZE:
                data_buf.seek(0)
                data_pos = 0
                # split the file up
                while data_pos < data_len:
                    new_buffer.append(io.BytesIO())
                    # copy the data - don't overstep the buffer
                    if data_pos + s3FileObject.MAXIMUM_PART_SIZE >= data_len:
                        sub_data = data_buf.read(data_len-data_pos)
                    else:
                        sub_data = data_buf.read(s3FileObject.MAXIMUM_PART_SIZE)
                    new_buffer[-1].write(sub_data)
                    # increment to next
                    data_pos += s3FileObject.MAXIMUM_PART_SIZE

                # free the old memory
                self._buffer[buffer_part].close()
            else:
                new_buffer.append(self._buffer[buffer_part])

        self._buffer = new_buffer

        for buffer_part in range(0, len(self._buffer)):
            # seek in the BytesIO buffer to get to the beginning after the
            # writing§
            self._buffer[buffer_part].seek(0)
            # upload here
            part = self._conn_obj.conn.upload_part(
                Bucket=self._bucket,
                Key=self._path,
                UploadId=self._upload_id,
                PartNumber=self._current_part,
                Body=self._buffer[buffer_part]
            )
            # insert into the multipart info list of dictionaries
            self._multipart_info['Parts'].append(
                {
                    'PartNumber' : self._current_part,
                    'ETag' : part['ETag']
                }
            )
            self._current_part += 1

        # reset all the byte buffers and their positions
        for buffer_part in range(0, len(self._buffer)):
            self._buffer[buffer_part].close()
        self._buffer = [io.BytesIO()]
        self._seek_pos = 0
        self._current_part += 1

    def write(self, b):
        """Write the given bytes-like object, b, and return the number of bytes
        written (always equal to the length of b in bytes, since if the write
        fails an OSError will be raised).
        For the S3 file object we just write the file to a temporary bytearray
        and increment the seek_pos.
        This data will be uploaded to an object when .flush is called.
        """
        if "w" not in self._mode:
            raise APIException(
                "Trying to write to a read only file, where mode != 'w'."
            )
        try:
            # add to local, temporary bytearray
            size = len(b)
            self._buffer[-1].write(b)
            self._seek_pos += size
            # test to see whether we should do a multipart upload now
            # this occurs when the number of buffers is > the maximum number of
            # parts.  self._current_part is indexed from 1
            if (self._multipart_upload and
                self._seek_pos > self._part_size):
                if len(self._buffer) == self._max_parts:
                    self._multipart_upload_from_buffer()
                else:
                    # add another buffer to write to
                    self._buffer.append(io.BytesIO())

        except ClientError as e:
            raise IOException(
                "Could not write to object {} {}".format(self._path, e)
            )
        except AttributeError as e:
            self._handle_connection_exception(e)

        return size

    def close(self):
        """Flush and close this stream. This method has no effect if the file is
        already closed. Once the file is closed, any operation on the file (e.g.
        reading or writing) will raise a ValueError.

        As a convenience, it is allowed to call this method more than once; only
        the first call, however, will have an effect."""
        try:
            if not self._closed:
                # self.flush will upload the buffer to the S3 store
                self.flush()
                s3FileObject._connection_pool.release(self._conn_obj)
                self._closed = True
        except AttributeError as e:
            self._handle_connection_exception(e)
        return True

    def seek(self, offset, whence=io.SEEK_SET):
        """Change the stream position to the given byte offset. offset is
        interpreted relative to the position indicated by whence. The default
        value for whence is SEEK_SET. Values for whence are:

        SEEK_SET or 0 – start of the stream (the default); offset should be zero
                        or positive
        SEEK_CUR or 1 – current stream position; offset may be negative
        SEEK_END or 2 – end of the stream; offset is usually negative
        Return the new absolute position.

        Note: currently cannot seek when writing a file.

        """
        if self._mode == 'w':
            raise IOException(
                "Cannot seek within a file that is being written to."
            )

        size = self._getsize()
        error_string = "Seek {} is outside file size bounds 0->{} for file {}"
        seek_pos = self._seek_pos
        if whence == io.SEEK_SET:
            # range check
            seek_pos = offset
        elif whence == io.SEEK_CUR:
            seek_pos += offset
        elif whence == io.SEEK_END:
            seek_pos = size - offset

        # range checks
        if (seek_pos >= size):
            raise IOException(error_string.format(
                seek_pos,
                size,
                self._path)
            )
        elif (seek_pos < 0):
            raise IOException(error_string.format(
                seek_pos,
                size,
                self._path)
            )
        self._seek_pos = seek_pos
        return self._seek_pos

    def seekable(self):
        """We can seek in s3 streams using the range get and range put features.
        """
        return True

    def tell(self):
        """Return True if the stream supports random access. If False, seek(),
        tell() and truncate() will raise OSError."""
        return self._seek_pos

    def fileno(self):
        """Return the underlying file descriptor (an integer) of the stream if
        it exists. An IOError is raised if the IO object does not use a file
        descriptor."""
        raise io.UnsupportedOperation

    def flush(self):
        """Flush the write buffers of the stream.  This will upload the contents
        of the final multipart upload of self._buffer to the S3 store."""
        try:
            if 'w' in self._mode:
                # if the size is less than the MAXIMUM UPLOAD SIZE
                # then just write the data
                size = self._buffer[0].tell()
                if self._current_part == 1 and size < s3FileObject.MAXIMUM_PART_SIZE:
                    if self._create_bucket:
                        # check whether the bucket exists and create if not
                        bucket_list = self._get_bucket_list()
                        if not self._bucket in bucket_list:
                            self._conn_obj.conn.create_bucket(
                                Bucket=self._bucket
                            )
                    # upload the whole buffer - seek back to the start first
                    self._buffer[0].seek(0)
                    self._conn_obj.conn.put_object(
                        Bucket=self._bucket,
                        Key=self._path,
                        Body=self._buffer[0].read(size)
                    )
                else:
                    # upload as multipart
                    self._multipart_upload_from_buffer()
                    # finalise the multipart upload
                    self._conn_obj.conn.complete_multipart_upload(
                        Bucket=self._bucket,
                        Key=self._path,
                        UploadId=self._upload_id,
                        MultipartUpload=self._multipart_info
                    )
        except AttributeError as e:
            self._handle_connection_exception(e)
        return True

    def readable(self):
        """Return True if the stream can be read from. If False, read() will
        raise IOError."""
        return 'r' in self._mode or '+' in self._mode

    def readline(self, size=-1):
        """Read and return one line from the stream.
        If size is specified, at most size bytes will be read."""
        if 'b' in self._mode:
            raise APIException(
                "readline on a binary file is not permitted: {}".format(
                    self._uri)
                )
        # only read a set number of bytes if size is passed in, otherwise
        # read upto the file size
        if size == -1:
            size = self._getsize()

        # use the BytesIO readline methods
        if self.tell() == 0:
            buffer = self.read(size=size)
            self._buffer[-1].write(buffer)
            self._buffer[-1].seek(0)

        line = self._buffer[-1].readline().decode().strip()
        return line

    def readlines(self, hint=-1):
        """Read and return a list of lines from the stream. hint can be
        specified to control the number of lines read: no more lines will be
        read if the total size (in bytes/characters) of all lines so far exceeds
        hint."""
        if 'b' in self._mode:
            raise APIException(
                "readline on a binary file is not permitted: {}".format(
                    self._uri)
                )
        # read the entire file in and decode it
        lines = self.read().decode().split("\n")
        return lines

    def truncate(self, size=None):
        """Not supported"""
        raise io.UnsupportedOperation

    def writable(self):
        """Return True if the stream supports writing. If False, write() and
        truncate() will raise IOError."""
        return 'w' in self._mode

    def writelines(self, lines):
        """Write a list of lines to the stream."""
        # first check if the file is binary or not
        if 'b' in self._mode:
            raise APIException(
                "writelines on a binary file is not permitted: {}".format(
                    self._uri)
                )
        # write all but the last line with a line break
        for l in lines:
            self.write((l+"\n").encode('utf-8'))
        return True

    def glob(self):
        """Emulate glob on an open bucket.  The glob has been passed in via
        self._path, created on connection to the server and bucket."""
        # get the path string up to the wildcards
        try:
            pi1 = self._path.index("*")
        except ValueError:
            pi1 = len(self._path)
        try:
            pi2 = self._path.index("?")
        except ValueError:
            pi2 = len(self._path)
        pi = min(pi1, pi2)
        # using the prefix will cut down on the search space
        prefix = self._path[:pi]
        # get the wildcard
        wildcard = self._path[pi:]
        # set up the paginator
        paginator = self._conn_obj.conn.get_paginator("list_objects_v2")
        parameters = {
            'Bucket': self._bucket,
            'Prefix': prefix
        }
        page_iterator = paginator.paginate(**parameters)
        files = []
        for page in page_iterator:
            for item in page.get('Contents', []):
                fname = item['Key']
                # check that it matches against wildcard
                if fnmatch.fnmatch(fname, wildcard):
                    files.append(item['Key'])
        return files
