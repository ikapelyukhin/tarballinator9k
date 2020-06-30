#!/usr/bin/ruby

require 'solv'
require 'rubygems'
require 'inifile'
require 'tempfile'
require 'pp'

require_relative './repo_generic.rb'
require_relative './repo_rpmmd.rb'
require_relative './repo_system.rb'
require_relative './repo_cutoff.rb'

class Tarballinator9k
  def initialize(repo_urls)
    @pool = Solv::Pool.new()
    @pool.setarch()

    @pool.set_loadcallback { |repodata|
      repo = repodata.repo.appdata
      repo ? repo.load_ext(repodata) : false
    }

    @repos = load_rpmmd_repos_from_urls(repo_urls)
    for repo in @repos
      repo.load(@pool) if repo.enabled?
    end
  end

  def load_rpmmd_repos_from_urls(urls)
    urls.map do |url|
      repo_alias = url.split('/')[5..-1].join("_")
      attrs = {
          'alias' => repo_alias,
          'enabled' => 1,
          'priority' => 99,
          'autorefresh' => 1,
          'type' => 'rpm-md',
          'metadata_expire' => 900,
          'baseurl' => url
      }
      Repo_rpmmd.new(repo_alias, 'repomd', attrs)
    end
  end

  def add_cutoff_packages(pool, cutoff_packages)
    return unless cutoff_packages.size > 0

    transaction = get_solver_transaction(cutoff_packages)
    transaction.order()

    cutoff_solvables = []
    for cl in transaction.classify(Solv::Transaction::SOLVER_TRANSACTION_SHOW_OBSOLETES | Solv::Transaction::SOLVER_TRANSACTION_OBSOLETE_IS_UPGRADE)
      for p in cl.solvables

        if cl.type == Solv::Transaction::SOLVER_TRANSACTION_UPGRADED || cl.type == Solv::Transaction::SOLVER_TRANSACTION_DOWNGRADED
          p = transaction.othersolvable(p)
        end

        cutoff_solvables << p
      end
    end

    dummyrepo = Repo_cutoff.new('@Cutoff', 'cutoff')

    # pool.createwhatprovides()
    #
    # cutoff_solvables = []
    #
    # cutoff_packages.each do |cutoff_package|
    #   sel = pool.Selection
    #   for di in pool.Dataiterator(Solv::SOLVABLE_NAME, cutoff_package, Solv::Dataiterator::SEARCH_STRING | Solv::Dataiterator::SEARCH_NOCASE)
    #     sel.add_raw(Solv::Job::SOLVER_SOLVABLE, di.solvid)
    #   end
    #
    #   result = []
    #   for s in sel.solvables
    #     next if s.arch == 'src'
    #     result << s
    #   end
    #
    #   raise "No results found for cutoff package #{cutoff_package}" unless result.size > 0
    #
    #   newest = result.sort { |a,b| a.evr <=> b.evr }.first
    #   cutoff_solvables << newest
    # end

    dummyrepo.load(pool, cutoff_solvables)
    dummyrepo
  end

  def get_solver_transaction(args)
    pool = @pool

    cmd = 'install'
    cmdactionmap = {
        'install' => Solv::Job::SOLVER_INSTALL,
        'erase'   => Solv::Job::SOLVER_ERASE,
        'up'      => Solv::Job::SOLVER_UPDATE,
        'dup'     => Solv::Job::SOLVER_DISTUPGRADE,
        'verify'  => Solv::Job::SOLVER_VERIFY,
        'list'    => 0,
        'info'    => 0,
    }

    jobs = []
    for arg in args
      flags = Solv::Selection::SELECTION_NAME | Solv::Selection::SELECTION_PROVIDES | Solv::Selection::SELECTION_GLOB
      flags |= Solv::Selection::SELECTION_CANON | Solv::Selection::SELECTION_DOTARCH | Solv::Selection::SELECTION_REL
      if arg =~ /^\//
        flags |= Solv::Selection::SELECTION_FILELIST
        flags |= Solv::Selection::SELECTION_INSTALLED_ONLY if cmd == 'erase'
      end
      sel = pool.select(arg, flags)
      if sel.isempty?
        sel = pool.select(arg, flags |  Solv::Selection::SELECTION_NOCASE)
        puts "[ignoring case for '#{arg}']" unless sel.isempty?
      end
      puts "[using file list match for '#{arg}']" if sel.flags & Solv::Selection::SELECTION_FILELIST != 0
      puts "[using capability match for '#{arg}']" if sel.flags & Solv::Selection::SELECTION_PROVIDES != 0
      jobs += sel.jobs(cmdactionmap[cmd])
    end

    if jobs.empty? && (cmd == 'up' || cmd == 'dup' || cmd == 'verify')
      sel = pool.Selection_all()
      jobs += sel.jobs(cmdactionmap[cmd])
    end

    abort("no package matched.") if jobs.empty?

    #####

    for job in jobs
      job.how ^= Solv::Job::SOLVER_UPDATE ^ Solv::Job::SOLVER_INSTALL if cmd == 'up' and job.isemptyupdate?
    end

    solver = pool.Solver
    solver.set_flag(Solv::Solver::SOLVER_FLAG_SPLITPROVIDES, 1)
    solver.set_flag(Solv::Solver::SOLVER_FLAG_IGNORE_RECOMMENDED, 1)
    solver.set_flag(Solv::Solver::SOLVER_FLAG_ALLOW_UNINSTALL, 1) if cmd == 'erase'

    # solver.set_flag(Solv::Solver::SOLVER_FLAG_ALLOW_VENDORCHANGE, 1)
    # solver.set_flag(Solv::Solver::SOLVER_FLAG_ALLOW_NAMECHANGE, 1)
    # solver.set_flag(Solv::Solver::SOLVER_FLAG_ALLOW_ARCHCHANGE, 1)

    # pool.set_debuglevel(1)

    while true
      problems = solver.solve(jobs)
      break if problems.empty?
      for problem in problems
        puts "Problem #{problem.id}/#{problems.count}:"
        puts problem
        solutions = problem.solutions
        for solution in solutions
          puts "  Solution #{solution.id}:"
          elements = solution.elements(true)
          for element in elements
            puts "  - #{element.str}"
          end
          puts
        end
        sol = nil
        while true
          print "Please choose a solution: "
          STDOUT.flush
          sol = STDIN.gets.strip
          break if sol == 's' || sol == 'q'
          break if sol =~ /^\d+$/ && sol.to_i >= 1 && sol.to_i <= solutions.length
        end

        next if sol == 's'
        abort if sol == 'q'

        solution = solutions[sol.to_i - 1]
        for element in solution.elements
          newjob = element.Job()
          if element.type == Solv::Solver::SOLVER_SOLUTION_JOB
            jobs[element.jobidx] = newjob
          else
            jobs.push(newjob) if newjob && !jobs.include?(newjob)
          end
        end
      end
    end

    transaction = solver.transaction
    solver = nil

    transaction
  end

  def print_transaction_summary(transaction)
    puts "\nTransaction summary:\n"
    for cl in transaction.classify(Solv::Transaction::SOLVER_TRANSACTION_SHOW_OBSOLETES | Solv::Transaction::SOLVER_TRANSACTION_OBSOLETE_IS_UPGRADE)
      if cl.type == Solv::Transaction::SOLVER_TRANSACTION_ERASE
        puts "#{cl.count} erased packages:"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_INSTALL
        puts "#{cl.count} installed packages:"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_REINSTALLED
        puts "#{cl.count} reinstalled packages:"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_DOWNGRADED
        puts "#{cl.count} downgraded packages:"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_CHANGED
        puts "#{cl.count} changed packages:"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_UPGRADED
        puts "#{cl.count} upgraded packages:"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_VENDORCHANGE
        puts "#{cl.count} vendor changes from '#{cl.fromstr}' to '#{cl.tostr}':"
      elsif cl.type == Solv::Transaction::SOLVER_TRANSACTION_ARCHCHANGE
        puts "#{cl.count} arch changes from '#{cl.fromstr}' to '#{cl.tostr}':"
      else
        next
      end
      for p in cl.solvables
        if cl.type == Solv::Transaction::SOLVER_TRANSACTION_UPGRADED || cl.type == Solv::Transaction::SOLVER_TRANSACTION_DOWNGRADED
          puts "  - #{p.str} -> #{transaction.othersolvable(p).str}"
        else
          puts "  - #{p.str}"
        end
      end
      puts
    end
    puts "install size change: #{transaction.calc_installsizechange()} K\n\n"
  end



  def tarballinate(cutoff_packages, packages_file, args)
    addedprovides = @pool.addfileprovides_queue()
    @repos.each { |repo| repo.updateaddedprovides(addedprovides) } if !addedprovides.empty?
    @pool.createwhatprovides()

    unless cutoff_packages.empty?
      add_cutoff_packages(@pool, cutoff_packages)
      @pool.createwhatprovides()
    end

    if packages_file
      sysrepo = Repo_system.new('@System', 'system')
      sysrepo.load(@pool, packages_file)

      addedprovides = @pool.addfileprovides_queue()
      @repos.each { |repo| repo.updateaddedprovides(addedprovides) } if !addedprovides.empty?
      sysrepo.updateaddedprovides(addedprovides)

      @pool.createwhatprovides()
    end

    #####

    transaction = get_solver_transaction(args)

    if transaction.isempty?
      puts "Nothing to do."
      exit
    end

    print_transaction_summary(transaction)
  end
end







sle_repos = %w[
  https://updates.suse.de/SUSE/Products/SLE-Product-SLES/15-SP1/x86_64/product/
  https://updates.suse.de/SUSE/Updates/SLE-Product-SLES/15-SP1/x86_64/update/
  https://updates.suse.de/SUSE/Products/SLE-Module-Basesystem/15-SP1/x86_64/product/
  https://updates.suse.de/SUSE/Updates/SLE-Module-Basesystem/15-SP1/x86_64/update/
  https://updates.suse.de/SUSE/Products/SLE-Module-Server-Applications/15-SP1/x86_64/product/
  https://updates.suse.de/SUSE/Updates/SLE-Module-Server-Applications/15-SP1/x86_64/update/
  https://updates.suse.de/SUSE/Products/SLE-Module-Web-Scripting/15-SP1/x86_64/product/
  https://updates.suse.de/SUSE/Updates/SLE-Module-Web-Scripting/15-SP1/x86_64/update/
  https://updates.suse.de/SUSE/Products/SLE-Module-Public-Cloud/15-SP1/x86_64/product/
  https://updates.suse.de/SUSE/Updates/SLE-Module-Public-Cloud/15-SP1/x86_64/update/
]

args = ARGV
cutoff_packages = %w[]
package_file = true

tarballinator = Tarballinator9k.new(sle_repos)
tarballinator.tarballinate(cutoff_packages, package_file, args)

























# cmd = args.shift

# cmdabbrev = { 'ls' => 'list', 'in' => 'install', 'rm' => 'erase',
#               've' => 'verify', 'se' => 'search' }
# cmd = cmdabbrev[cmd] if cmdabbrev.has_key?(cmd)

# exit()

# if cmd == 'search'
#   pool.createwhatprovides()
#   sel = pool.Selection
#   #for di in pool.Dataiterator(Solv::SOLVABLE_NAME, args[0], Solv::Dataiterator::SEARCH_SUBSTRING | Solv::Dataiterator::SEARCH_NOCASE)
#   for di in pool.Dataiterator(Solv::SOLVABLE_NAME, args[0], Solv::Dataiterator::SEARCH_STRING | Solv::Dataiterator::SEARCH_NOCASE)
#     sel.add_raw(Solv::Job::SOLVER_SOLVABLE, di.solvid)
#   end
#   for s in sel.solvables
#     puts "- #{s.str} [#{s.repo.name}]: #{s.lookup_str(Solv::SOLVABLE_SUMMARY)}"
#   end
#   exit
# end

# abort("unknown command '#{cmd}'\n") unless cmdactionmap.has_key?(cmd)
#
# if cmd == 'list' || cmd == 'info'
#   for job in jobs
#     for s in job.solvables()
#       if cmd == 'info'
# 	puts "Name:        #{s.str}"
# 	puts "Repo:        #{s.repo.name}"
# 	puts "Summary:     #{s.lookup_str(Solv::SOLVABLE_SUMMARY)}"
# 	str = s.lookup_str(Solv::SOLVABLE_URL)
# 	puts "Url:         #{str}" if str
# 	str = s.lookup_str(Solv::SOLVABLE_LICENSE)
# 	puts "License:     #{str}" if str
# 	puts "Description:\n#{s.lookup_str(Solv::SOLVABLE_DESCRIPTION)}"
# 	puts
#       else
# 	puts "  - #{s.str} [#{s.repo.name}]"
# 	puts "    #{s.lookup_str(Solv::SOLVABLE_SUMMARY)}"
#       end
#     end
#   end
#   exit
# end



# while true
#   print("OK to continue (y/n)? ")
#   STDOUT.flush
#   yn = STDIN.gets.strip
#   break if yn == 'y'
#   abort if yn == 'n' || yn == 'q'
# end

# newpkgs = trans.newsolvables()

# pp trans.order()
# steps = trans.steps()
# pp steps
#
# puts "Exiting"
# exit()
#
# newpkgsfp = {}
# if !newpkgs.empty?
#   downloadsize = 0
#   for p in newpkgs
#     downloadsize += p.lookup_num(Solv::SOLVABLE_DOWNLOADSIZE)
#   end
#   puts "Downloading #{newpkgs.length} packages, #{downloadsize / 1024} K"
#   for p in newpkgs
#     repo = p.repo.appdata
#     location, medianr = p.lookup_location()
#     next unless location
#     location = repo.packagespath + location
#     chksum = p.lookup_checksum(Solv::SOLVABLE_CHECKSUM)
#     f = repo.download(location, false, chksum)
#     abort("\n#{@name}: #{location} not found in repository\n") unless f
#     newpkgsfp[p.id] = f
#     print "."
#     STDOUT.flush()
#   end
#   puts
# end
#
# puts "Committing transaction:"
# puts
# trans.order()
# for p in trans.steps
#   steptype = trans.steptype(p, Solv::Transaction::SOLVER_TRANSACTION_RPM_ONLY)
#   if steptype == Solv::Transaction::SOLVER_TRANSACTION_ERASE
#     puts "erase #{p.str}"
#     next unless p.lookup_num(Solv::RPM_RPMDBID)
#     evr = p.evr.sub(/^[0-9]+:/, '')
#     system('rpm', '-e', '--nodeps', '--nodigest', '--nosignature', "#{p.name}-#{evr}.#{p.arch}") || abort("rpm failed: #{$? >> 8}")
#   elsif (steptype == Solv::Transaction::SOLVER_TRANSACTION_INSTALL || steptype == Solv::Transaction::SOLVER_TRANSACTION_MULTIINSTALL)
#     puts "install #{p.str}"
#     f = newpkgsfp.delete(p.id)
#     next unless f
#     mode = steptype == Solv::Transaction::SOLVER_TRANSACTION_INSTALL ? '-U' : '-i'
#     f.cloexec(0)
#     system('rpm', mode, '--force', '--nodeps', '--nodigest', '--nosignature', "/dev/fd/#{f.fileno().to_s}") || abort("rpm failed: #{$? >> 8}")
#     f.close
#   end
# end


