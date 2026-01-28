#!/usr/bin/env elixir
#
# Regression test for GitHub issue #59
# Verifies that the hex package can be compiled as a dependency.
# This catches issues like missing files in the package (e.g., .formatter.exs).

defmodule HexPackageTest do
  def run do
    IO.puts("Building hex package...")

    {output, exit_code} =
      System.cmd("mix", ["hex.build", "-o", "peep-test.tar"], stderr_to_stdout: true)

    if exit_code != 0 do
      IO.puts("FAILED to build hex package: #{output}")
      System.halt(1)
    end

    test_dir = Path.join(System.tmp_dir!(), "peep_install_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)

    try do
      # Extract the hex package (contains VERSION, CHECKSUM, metadata.config, contents.tar.gz)
      {_, 0} = System.cmd("tar", ["-xf", "peep-test.tar", "-C", test_dir])

      # Extract the actual source files from contents.tar.gz
      pkg_dir = Path.join(test_dir, "peep_pkg")
      File.mkdir_p!(pkg_dir)
      {_, 0} = System.cmd("tar", ["-xzf", Path.join(test_dir, "contents.tar.gz"), "-C", pkg_dir])

      # Create a minimal test project that depends on peep
      project_dir = Path.join(test_dir, "test_project")
      File.mkdir_p!(project_dir)

      main_deps_path = Path.expand("deps")
      project_deps = Path.join(project_dir, "deps")

      File.ln_s!(main_deps_path, project_deps)

      mix_exs = """
      defmodule TestProject.MixProject do
        use Mix.Project

        def project do
          [
            app: :test_project,
            version: "0.1.0",
            elixir: "~> 1.15",
            deps: [{:peep, path: "#{pkg_dir}"}]
          ]
        end
      end
      """

      File.write!(Path.join(project_dir, "mix.exs"), mix_exs)
      File.mkdir_p!(Path.join(project_dir, "lib"))
      File.write!(Path.join(project_dir, "lib/test_project.ex"), "defmodule TestProject do\nend")

      # Symlink the lock file from the main project
      File.ln_s!(Path.expand("mix.lock"), Path.join(project_dir, "mix.lock"))

      # Try to compile - this is what fails in issue #59
      IO.puts("Compiling test project with peep as dependency...")

      {output, exit_code} =
        System.cmd("mix", ["compile"],
          cd: project_dir,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "prod"}]
        )

      if exit_code != 0 do
        IO.puts("FAILED to compile peep as dependency:\n#{output}")
        System.halt(1)
      end

      IO.puts("SUCCESS: peep compiles correctly as a dependency")
    after
      File.rm_rf!(test_dir)
      File.rm("peep-test.tar")
    end
  end
end

HexPackageTest.run()
