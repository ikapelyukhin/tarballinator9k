class Repo_generic
  def initialize(name, type, attribs = {})
    @name = name
    @type = type
    @attribs = attribs.dup
    @incomplete = false
    @cache_dir = File.join(__dir__, 'cache')
  end

  def enabled?
    return @attribs['enabled'].to_i != 0
  end

  def autorefresh?
    return @attribs['autorefresh'].to_i != 0
  end

  def id
    return @handle ? @handle.id : 0
  end

  def calc_cookie_fp(f)
    chksum = Solv::Chksum.new(Solv::REPOKEY_TYPE_SHA256)
    chksum.add("1.1")
    chksum.add_fp(f)
    return chksum.raw
  end

  def calc_cookie_file(filename)
    chksum = Solv::Chksum.new(Solv::REPOKEY_TYPE_SHA256)
    chksum.add("1.1")
    chksum.add_stat(filename)
    return chksum.raw
  end

  def calc_cookie_ext(f, cookie)
    chksum = Solv::Chksum.new(Solv::REPOKEY_TYPE_SHA256)
    chksum.add("1.1")
    chksum.add(cookie)
    chksum.add_fstat(f.fileno)
    return chksum.raw()
  end

  def cachepath(ext = nil)
    path = @name.sub(/^\./, '_')
    path += ext ? "_#{ext}.solvx" : '.solv'
    return File.join(@cache_dir, path.gsub(/\//, '_'))
  end

  def load(pool)
    @handle = pool.add_repo(@name)
    @handle.appdata = self
    @handle.priority = 99 - @attribs['priority'].to_i if @attribs['priority']
    dorefresh = autorefresh?
    if dorefresh
      begin
        s = File.stat(cachepath)
        dorefresh = false if s && (@attribs['metadata_expire'].to_i == -1 || Time.now - s.mtime < @attribs['metadata_expire'].to_i)
      rescue SystemCallError
      end
    end
    @cookie = nil
    @extcookie = nil
    if !dorefresh && usecachedrepo(nil)
      puts "repo: '#{@name}' cached"
      return true
    end
    return false
  end

  def load_ext(repodata)
    return false
  end

  def download(file, uncompress, chksum, markincomplete = false)
    url = @attribs['baseurl']
    if !url
      puts "%{@name}: no baseurl"
      return nil
    end
    url = url.sub(/\/$/, '') + "/#{file}"

    f =  Tempfile.new('rbsolv')
    f.unlink

    temp_fname = "/proc/#{$$}/fd/#{f.fileno}"

    st = system('curl', '-f', '-s', '-L', '-o', temp_fname, '--', url)
    return nil if f.stat.size == 0 && (st || !chksum)
    if !st
      puts "#{file}: download error #{$? >> 8}"
      @incomplete = true if markincomplete
      return nil
    end
    if chksum
      fchksum = Solv::Chksum.new(chksum.type)
      fchksum.add_fd(f.fileno)
      if !fchksum == chksum
        puts "#{file}: checksum error"
        @incomplete = true if markincomplete
        return nil
      end
    end
    rf = nil
    if uncompress
      rf = Solv::xfopen_fd(file, f.fileno)
    else
      rf = Solv::xfopen_fd('', f.fileno)
    end
    f.close
    return rf
  end

  def usecachedrepo(ext, mark = false)
    cookie = ext ? @extcookie : @cookie
    begin
      repopath = cachepath(ext)
      f = File.new(repopath, "r")
      f.sysseek(-32, IO::SEEK_END)
      fcookie = f.sysread(32)
      return false if fcookie.length != 32
      return false if cookie && fcookie != cookie
      if !ext && @type != 'system'
        f.sysseek(-32 * 2, IO::SEEK_END)
        fextcookie = f.sysread(32)
        return false if fextcookie.length != 32
      end
      f.sysseek(0, IO::SEEK_SET)
      nf = Solv::xfopen_fd('', f.fileno)
      f.close
      flags = ext ? Solv::Repo::REPO_USE_LOADING|Solv::Repo::REPO_EXTEND_SOLVABLES : 0
      flags |= Solv::Repo::REPO_LOCALPOOL if ext && ext != 'DL'
      if ! @handle.add_solv(nf, flags)
        nf.close
        return false
      end
      nf.close()
      @cookie = fcookie unless ext
      @extcookie = fextcookie if !ext && @type != 'system'
      now = Time.now
      begin
        File::utime(now, now, repopath) if mark
      rescue SystemCallError
      end
      return true
    rescue SystemCallError
      return false
    end
    return true
  end

  def writecachedrepo(ext, repodata = nil)
    return if @incomplete
    begin
      Dir::mkdir(@cache_dir, 0755) unless FileTest.directory?(@cache_dir)
      f =  Tempfile.new('.newsolv-', @cache_dir)
      f.chmod(0444)
      sf = Solv::xfopen_fd('', f.fileno)
      if !repodata
        @handle.write(sf)
      elsif ext
        repodata.write(sf)
      else
        @handle.write_first_repodata(sf)
      end
      sf.close
      f.sysseek(0, IO::SEEK_END)
      if @type != 'system' && !ext
        @extcookie = calc_cookie_ext(f, @cookie) unless @extcookie
        f.syswrite(@extcookie)
      end
      f.syswrite(ext ? @extcookie : @cookie)
      f.close
      if @handle.iscontiguous?
        sf = Solv::xfopen(f.path)
        if sf
          if !ext
            @handle.empty()
            abort("internal error, cannot reload solv file") unless @handle.add_solv(sf, repodata ? 0 : Solv::Repo::SOLV_ADD_NO_STUBS)
          else
            repodata.extend_to_repo()
            flags = Solv::Repo::REPO_EXTEND_SOLVABLES
            flags |= Solv::Repo::REPO_LOCALPOOL if ext != 'DL'
            repodata.add_solv(sf, flags)
          end
          sf.close
        end
      end
      File.rename(f.path, cachepath(ext))
      f.unlink
      return true
    rescue SystemCallError
      return false
    end
  end

  def updateaddedprovides(addedprovides)
    return if @incomplete
    return unless @handle && !@handle.isempty?
    repodata = @handle.first_repodata()
    return unless repodata
    oldaddedprovides = repodata.lookup_idarray(Solv::SOLVID_META, Solv::REPOSITORY_ADDEDFILEPROVIDES)
    return if (oldaddedprovides | addedprovides) == oldaddedprovides
    for id in addedprovides
      repodata.add_idarray(Solv::SOLVID_META, Solv::REPOSITORY_ADDEDFILEPROVIDES, id)
    end
    repodata.internalize()
    writecachedrepo(nil, repodata)
  end

  def packagespath()
    return ''
  end

  @@langtags = {
      Solv::SOLVABLE_SUMMARY     => Solv::REPOKEY_TYPE_STR,
      Solv::SOLVABLE_DESCRIPTION => Solv::REPOKEY_TYPE_STR,
      Solv::SOLVABLE_EULA        => Solv::REPOKEY_TYPE_STR,
      Solv::SOLVABLE_MESSAGEINS  => Solv::REPOKEY_TYPE_STR,
      Solv::SOLVABLE_MESSAGEDEL  => Solv::REPOKEY_TYPE_STR,
      Solv::SOLVABLE_CATEGORY    => Solv::REPOKEY_TYPE_ID,
  }

  def add_ext_keys(ext, repodata, h)
    if ext == 'DL'
      repodata.add_idarray(h, Solv::REPOSITORY_KEYS, Solv::REPOSITORY_DELTAINFO)
      repodata.add_idarray(h, Solv::REPOSITORY_KEYS, Solv::REPOKEY_TYPE_FLEXARRAY)
    elsif ext == 'DU'
      repodata.add_idarray(h, Solv::REPOSITORY_KEYS, Solv::SOLVABLE_DISKUSAGE)
      repodata.add_idarray(h, Solv::REPOSITORY_KEYS, Solv::REPOKEY_TYPE_DIRNUMNUMARRAY)
    elsif ext == 'FL'
      repodata.add_idarray(h, Solv::REPOSITORY_KEYS, Solv::SOLVABLE_FILELIST)
      repodata.add_idarray(h, Solv::REPOSITORY_KEYS, Solv::REPOKEY_TYPE_DIRSTRARRAY)
    else
      @@langtags.sort.each do |langid, langtype|
        repodata.add_idarray(h, Solv::REPOSITORY_KEYS, @handle.pool.id2langid(langid, ext, true))
        repodata.add_idarray(h, Solv::REPOSITORY_KEYS, langtype)
      end
    end
  end
end