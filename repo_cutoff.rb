class Repo_cutoff < Repo_generic
  def load(pool, cutoff_solvables)
    @handle = pool.add_repo(@name)
    @handle.appdata = self
    pool.installed = @handle

    cutoff_solvables.each do |cutoff_solvable|
      dummy_solvable = @handle.add_solvable()

      dummy_solvable.nameid = cutoff_solvable.nameid
      dummy_solvable.evrid = cutoff_solvable.evrid
      dummy_solvable.archid = cutoff_solvable.archid
      dummy_solvable.vendorid = cutoff_solvable.vendorid

      attrs = [
          # Solv::SOLVABLE_NAME,
          # Solv::SOLVABLE_ARCH,
          # Solv::SOLVABLE_EVR,
          # Solv::SOLVABLE_VENDOR,
          Solv::SOLVABLE_PROVIDES,
          Solv::SOLVABLE_OBSOLETES,
          Solv::SOLVABLE_CONFLICTS,
          Solv::SOLVABLE_REQUIRES,
          Solv::SOLVABLE_RECOMMENDS,
          Solv::SOLVABLE_SUGGESTS,
          Solv::SOLVABLE_SUPPLEMENTS,
          Solv::SOLVABLE_ENHANCES
      ]

      attrs.each do |attr|
        val = cutoff_solvable.lookup_deparray(attr, 0)

        val.each do |dep|
          dummy_solvable.add_deparray(attr, dep)
        end

        # puts "#{Solv.constants.find { |c| Solv.const_get(c).equal?(attr) }}:"
        # puts ""
        # puts dummy_solvable.lookup_deparray(attr, 0).map { |i| i.to_s }.join(",\n")
        # puts ""
      end

        # puts "dummy package #{cutoff_solvable} is identical to cutoff package: #{cutoff_solvable.identical?(dummy_solvable)}"
    end

    @handle.internalize()

    return true
  end
end