class Repo_system < Repo_generic
  def load(pool, packages_file)
    @handle = pool.add_repo(@name)
    @handle.appdata = self
    pool.installed = @handle

    print "rpm database: "
    # @cookie = calc_cookie_file(packages_file)
    if usecachedrepo(nil)
      puts "cached"
      return true
    end

    raise "Whoops"
    # puts "reading"

    # FIXME is this needed or not
    # if @handle.respond_to? :add_products
    #   @handle.add_products("/etc/products.d", Solv::Repo::REPO_NO_INTERNALIZE)
    # end

    f = Solv::xfopen(cachepath())
    @handle.add_rpmdb_reffp(f, Solv::Repo::REPO_REUSE_REPODATA)
    f.close if f

    #writecachedrepo(nil)

    return true
  end
end