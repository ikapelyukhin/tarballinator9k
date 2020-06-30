class Repo_rpmmd < Repo_generic

  def find(what)
    di = @handle.Dataiterator_meta(Solv::REPOSITORY_REPOMD_TYPE, what, Solv::Dataiterator::SEARCH_STRING)
    di.prepend_keyname(Solv::REPOSITORY_REPOMD)
    for d in di
      dp = d.parentpos()
      filename = dp.lookup_str(Solv::REPOSITORY_REPOMD_LOCATION)
      next unless filename
      checksum = dp.lookup_checksum(Solv::REPOSITORY_REPOMD_CHECKSUM)
      if !checksum
        puts "no #{filename} checksum!"
        return nil, nil
      end
      return filename, checksum
    end
    return nil, nil
  end

  def load(pool)
    return true if super(pool)
    print "rpmmd repo '#{@name}: "
    f = download("repodata/repomd.xml", false, nil, nil)
    if !f
      puts "no repomd.xml file, skipped"
      @handle.free(true)
      @handle = nil
      return false
    end
    @cookie = calc_cookie_fp(f)
    if usecachedrepo(nil, true)
      puts "cached"
      f.close
      return true
    end
    @handle.add_repomdxml(f, 0)
    f.close
    puts "fetching"
    filename, filechksum = find('primary')
    if filename
      f = download(filename, true, filechksum, true)
      if f
        @handle.add_rpmmd(f, nil, 0)
        f.close
      end
      return false if @incomplete
    end
    filename, filechksum = find('updateinfo')
    if filename
      f = download(filename, true, filechksum, true)
      if f
        @handle.add_updateinfoxml(f, 0)
        f.close
      end
    end
    add_exts()
    writecachedrepo(nil)
    @handle.create_stubs()
    return true
  end

  def add_ext(repodata, what, ext)
    filename, filechksum = find(what)
    filename, filechksum = find('prestodelta') if !filename && what == 'deltainfo'
    return unless filename
    h = repodata.new_handle()
    repodata.set_poolstr(h, Solv::REPOSITORY_REPOMD_TYPE, what)
    repodata.set_str(h, Solv::REPOSITORY_REPOMD_LOCATION, filename)
    repodata.set_checksum(h, Solv::REPOSITORY_REPOMD_CHECKSUM, filechksum)
    add_ext_keys(ext, repodata, h)
    repodata.add_flexarray(Solv::SOLVID_META, Solv::REPOSITORY_EXTERNAL, h)
  end

  def add_exts
    repodata = @handle.add_repodata(0)
    repodata.extend_to_repo()
    add_ext(repodata, 'deltainfo', 'DL')
    add_ext(repodata, 'filelists', 'FL')
    repodata.internalize()
  end

  def load_ext(repodata)
    repomdtype = repodata.lookup_str(Solv::SOLVID_META, Solv::REPOSITORY_REPOMD_TYPE)
    if repomdtype == 'filelists'
      ext = 'FL'
    elsif repomdtype == 'deltainfo'
      ext = 'DL'
    else
      return false
    end
    print "[#{@name}:#{ext}: "
    STDOUT.flush
    if usecachedrepo(ext)
      puts "cached]\n"
      return true
    end
    puts "fetching]\n"
    filename = repodata.lookup_str(Solv::SOLVID_META, Solv::REPOSITORY_REPOMD_LOCATION)
    filechksum = repodata.lookup_checksum(Solv::SOLVID_META, Solv::REPOSITORY_REPOMD_CHECKSUM)
    f = download(filename, true, filechksum)
    return false unless f
    if ext == 'FL'
      @handle.add_rpmmd(f, 'FL', Solv::Repo::REPO_USE_LOADING|Solv::Repo::REPO_EXTEND_SOLVABLES|Solv::Repo::REPO_LOCALPOOL)
    elsif ext == 'DL'
      @handle.add_deltainfoxml(f, Solv::Repo::REPO_USE_LOADING)
    end
    f.close
    writecachedrepo(ext, repodata)
    return true
  end

end
