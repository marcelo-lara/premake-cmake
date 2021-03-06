	--
-- cmake_cpp.lua
-- Generate a C/C++ CMake project.
-- Copyright (c) 2014 Manu Evans and the Premake project
--

	premake.extensions.cmake.d = {}

	local cmake = premake.extensions.cmake
	local d = cmake.d
	local project = premake.project
	local config = premake.config
	local fileconfig = premake.fileconfig


---
-- Add namespace for element definition lists for premake.callarray()
---

	d.elements = {}


--
-- Generate a GNU make C++ project makefile, with support for the new platforms API.
--

	d.elements.makefile = {
		"header",
		"phonyRules",
		"dConfigs",
		"dObjects",
		"shellType",
		"dTargetRules",
		"targetDirRules",
		"objDirRules",
		"dCleanRules",
		"preBuildRules",
		"preLinkRules",
		"pchRules",
		"dFileRules",
		"dDependencies",
	}

	function cmake.d.generate(prj)
		premake.eol("\n")
		premake.callarray(make, d.elements.makefile, prj)
	end


--
-- Write out the settings for a particular configuration.
--

	d.elements.configuration = {
		"dTools",
		"target",
		"objdir",
		"pch",
		"defines",
		"includes",
		"forceInclude",
		"dFlags",
		"cFlags",
		"cxxFlags",
		"resFlags",
		"libs",
		"ldDeps",
		"ldFlags",
		"linkCmd",
		"preBuildCmds",
		"preLinkCmds",
		"postBuildCmds",
		"dAllRules",
		"settings",
	}

	function cmake.d(prj)
		for cfg in project.eachconfig(prj) do
			-- identify the toolset used by this configurations (would be nicer if
			-- this were computed and stored with the configuration up front)

			local toolset = premake.tools[cfg.toolset or "gcc"]
			if not toolset then
				error("Invalid toolset '" + cfg.toolset + "'")
			end

			_x('ifeq ($(config),%s)', cfg.shortname)
			premake.callarray(make, d.elements.configuration, cfg, toolset)
			_p('endif')
			_p('')
		end
	end


--
-- Build command for a single file.
--

	function d.buildcommand(prj, objext, node)
		local iscfile = node and path.iscfile(node.abspath) or false
		local flags = iif(prj.language == "D" or iscfile, '$(DC) $(ALL_DFLAGS)', '$(DXX) $(ALL_DXXFLAGS)')
		_p('\t$(SILENT) %s $(FORCE_INCLUDE) -o "$@" -MF $(@:%%.%s=%%.d) -c "$<"', flags, objext)
	end


--
-- Output the list of file building rules.
--

	function make.dFileRules(prj)
		local tr = project.getsourcetree(prj)
		premake.tree.traverse(tr, {
			onleaf = function(node, depth)
				-- check to see if this file has custom rules
				local rules
				for cfg in project.eachconfig(prj) do
					local filecfg = fileconfig.getconfig(node, cfg)
					if fileconfig.hasCustomBuildRule(filecfg) then
						rules = true
						break
					end
				end

				-- if it has custom rules, need to break them out
				-- into individual configurations
				if rules then
					d.customFileRules(prj, node)
				else
					d.standardFileRules(prj, node)
				end
			end
		})
		_p('')
	end

	function d.standardFileRules(prj, node)
		-- C/C++ file
		if path.isdfile(node.abspath) then
			_x('$(OBJDIR)/%s.o: %s', node.objname, node.relpath)
			_p('\t@echo $(notdir $<)')
			d.buildcommand(prj, "o", node)

		-- resource file
		elseif path.isresourcefile(node.abspath) then
			_x('$(OBJDIR)/%s.res: %s', node.objname, node.relpath)
			_p('\t@echo $(notdir $<)')
			_p('\t$(SILENT) $(RESCOMP) $< -O coff -o "$@" $(ALL_RESFLAGS)')
		end
	end

	function d.customFileRules(prj, node)
		for cfg in project.eachconfig(prj) do
			local filecfg = fileconfig.getconfig(node, cfg)
			if filecfg then
				_x('ifeq ($(config),%s)', cfg.shortname)

				local output = project.getrelative(prj, filecfg.buildoutputs[1])
				_x('%s: %s', output, filecfg.relpath)
				_p('\t@echo "%s"', filecfg.buildmessage or ("Building " .. filecfg.relpath))
				for _, cmd in ipairs(filecfg.buildcommands) do
					_p('\t$(SILENT) %s', cmd)
				end
				_p('endif')
			end
		end
	end


--
-- List the objects file for the project, and each configuration.
--

	function make.dObjects(prj)
		-- create lists for intermediate files, at the project level and
		-- for each configuration
		local root = { objects={}, resources={} }
		local configs = {}
		for cfg in project.eachconfig(prj) do
			configs[cfg] = { objects={}, resources={} }
		end

		-- now walk the list of files in the project
		local tr = project.getsourcetree(prj)
		premake.tree.traverse(tr, {
			onleaf = function(node, depth)
				-- figure out what configurations contain this file, and
				-- if it uses custom build rules
				local incfg = {}
				local inall = true
				local custom = false
				for cfg in project.eachconfig(prj) do
					local filecfg = fileconfig.getconfig(node, cfg)
					if filecfg and not filecfg.flags.ExcludeFromBuild then
						incfg[cfg] = filecfg
						custom = fileconfig.hasCustomBuildRule(filecfg)
					else
						inall = false
					end
				end

				if not custom then
					-- identify the file type
					local kind
					if path.isdfile(node.abspath) then
						kind = "objects"
					elseif path.isresourcefile(node.abspath) then
						kind = "resources"
					end

					-- skip files that aren't compiled
					if not custom and not kind then
						return
					end

					-- assign a unique object file name to avoid collisions
					objectname = "$(OBJDIR)/" .. node.objname .. iif(kind == "objects", ".o", ".res")

					-- if this file exists in all configurations, write it to
					-- the project's list of files, else add to specific cfgs
					if inall then
						table.insert(root[kind], objectname)
					else
						for cfg in project.eachconfig(prj) do
							if incfg[cfg] then
								table.insert(configs[cfg][kind], objectname)
							end
						end
					end

				else
					for cfg in project.eachconfig(prj) do
						local filecfg = incfg[cfg]
						if filecfg then
							-- if the custom build outputs an object file, add it to
							-- the link step automatically to match Visual Studio
							local output = project.getrelative(prj, filecfg.buildoutputs[1])
							if path.isobjectfile(output) then
								table.insert(configs[cfg].objects, output)
							end
						end
					end
				end

			end
		})

		-- now I can write out the lists, project level first...
		function listobjects(var, list)
			_p('%s \\', var)
			for _, objectname in ipairs(list) do
				_x('\t%s \\', objectname)
			end
			_p('')
		end

		listobjects('OBJECTS :=', root.objects, 'o')
		listobjects('RESOURCES :=', root.resources, 'res')

		-- ...then individual configurations, as needed
		for cfg in project.eachconfig(prj) do
			local files = configs[cfg]
			if #files.objects > 0 or #files.resources > 0 then
				_x('ifeq ($(config),%s)', cfg.shortname)
				if #files.objects > 0 then
					listobjects('  OBJECTS +=', files.objects)
				end
				if #files.resources > 0 then
					listobjects('  RESOURCES +=', files.resources)
				end
				_p('endif')
				_p('')
			end
		end
	end


---------------------------------------------------------------------------
--
-- Handlers for individual makefile elements
--
---------------------------------------------------------------------------

	function make.cFlags(cfg, toolset)
		_p('  ALL_DFLAGS += $(DFLAGS) $(ALL_DFLAGS) $(ARCH)%s', make.list(table.join(toolset.getcflags(cfg), cfg.buildoptions)))
	end


	function make.dAllRules(cfg, toolset)
		if cfg.system == premake.MACOSX and cfg.kind == premake.WINDOWEDAPP then
			_p('all: $(TARGETDIR) $(OBJDIR) prebuild prelink $(TARGET) $(dir $(TARGETDIR))PkgInfo $(dir $(TARGETDIR))Info.plist')
			_p('\t@:')
			_p('')
			_p('$(dir $(TARGETDIR))PkgInfo:')
			_p('$(dir $(TARGETDIR))Info.plist:')
		else
			_p('all: $(TARGETDIR) $(OBJDIR) prebuild prelink $(TARGET)')
			_p('\t@:')
		end
	end


	function make.dFlags(cfg, toolset)
		_p('  ALL_DFLAGS += $(DFLAGS)%s $(DEFINES) $(INCLUDES)', make.list(toolset.getdflags(cfg)))
	end


	function make.cxxFlags(cfg, toolset)
		_p('  ALL_CXXFLAGS += $(CXXFLAGS) $(ALL_CFLAGS)%s', make.list(toolset.getcxxflags(cfg)))
	end


	function make.dCleanRules(prj)
		_p('clean:')
		_p('\t@echo Cleaning %s', prj.name)
		_p('ifeq (posix,$(SHELLTYPE))')
		_p('\t$(SILENT) rm -f  $(TARGET)')
		_p('\t$(SILENT) rm -rf $(OBJDIR)')
		_p('else')
		_p('\t$(SILENT) if exist $(subst /,\\\\,$(TARGET)) del $(subst /,\\\\,$(TARGET))')
		_p('\t$(SILENT) if exist $(subst /,\\\\,$(OBJDIR)) rmdir /s /q $(subst /,\\\\,$(OBJDIR))')
		_p('endif')
		_p('')
	end


	function make.dDependencies(prj)
		-- include the dependencies, built by GCC (with the -MMD flag)
		_p('-include $(OBJECTS:%%.o=%%.d)')
		_p('ifneq (,$(PCH))')
			_p('  -include $(OBJDIR)/$(notdir $(PCH)).d')
		_p('endif')
	end


	function make.dTargetRules(prj)
		_p('$(TARGET): $(GCH) $(OBJECTS) $(LDDEPS) $(RESOURCES)')
		_p('\t@echo Linking %s', prj.name)
		_p('\t$(SILENT) $(LINKCMD)')
		_p('\t$(POSTBUILDCMDS)')
		_p('')
	end


	function make.dTools(cfg, toolset)
		local tool = toolset.gettoolname(cfg, "cc")
		if tool then
			_p('  D = %s', tool)
		end

		tool = toolset.gettoolname(cfg, "ar")
		if tool then
			_p('  AR = %s', tool)
		end

		tool = toolset.gettoolname(cfg, "rc")
		if tool then
			_p('  RESCOMP = %s', tool)
		end
	end


	function make.defines(cfg, toolset)
		_p('  DEFINES +=%s', make.list(toolset.getdefines(cfg.defines)))
	end


	function make.forceInclude(cfg, toolset)
		local includes = toolset.getforceincludes(cfg)
		if not cfg.flags.NoPCH and cfg.pchheader then
			table.insert(includes, "-include $(OBJDIR)/$(notdir $(PCH))")
		end
		_x('  FORCE_INCLUDE +=%s', make.list(includes))
	end


	function make.includes(cfg, toolset)
		local includes = premake.esc(toolset.getincludedirs(cfg, cfg.includedirs))
		_p('  INCLUDES +=%s', make.list(includes))
	end


	function make.ldDeps(cfg, toolset)
		local deps = config.getlinks(cfg, "siblings", "fullpath")
		_p('  LDDEPS +=%s', make.list(premake.esc(deps)))
	end


	function make.ldFlags(cfg, toolset)
		_p('  ALL_LDFLAGS += $(LDFLAGS)%s', make.list(table.join(toolset.getldflags(cfg), cfg.linkoptions)))
	end


	function make.libs(cfg, toolset)
		local flags = toolset.getlinks(cfg)
		_p('  LIBS +=%s', make.list(flags))
	end


	function make.linkCmd(cfg, toolset)
		if cfg.kind == premake.STATICLIB then
			if cfg.architecture == premake.UNIVERSAL then
				_p('  LINKCMD = libtool -o $(TARGET) $(OBJECTS)')
			else
				_p('  LINKCMD = $(AR) -rcs $(TARGET) $(OBJECTS)')
			end
		else
			-- this was $(TARGET) $(LDFLAGS) $(OBJECTS)
			--   but had trouble linking to certain static libs; $(OBJECTS) moved up
			-- $(LDFLAGS) moved to end (http://sourceforge.net/p/premake/patches/107/)
			-- $(LIBS) moved to end (http://sourceforge.net/p/premake/bugs/279/)

			local cc = iif(cfg.language == "C", "CC", "CXX")
			_p('  LINKCMD = $(%s) -o $(TARGET) $(OBJECTS) $(RESOURCES) $(ARCH) $(ALL_LDFLAGS) $(LIBS)', cc)
		end
	end


	function make.pch(cfg, toolset)
		-- If there is no header, or if PCH has been disabled, I can early out
		if not cfg.pchheader or cfg.flags.NoPCH then
			return
		end

		-- Visual Studio requires the PCH header to be specified in the same way
		-- it appears in the #include statements used in the source code; the PCH
		-- source actual handles the compilation of the header. GCC compiles the
		-- header file directly, and needs the file's actual file system path in
		-- order to locate it.

		-- To maximize the compatibility between the two approaches, see if I can
		-- locate the specified PCH header on one of the include file search paths
		-- and, if so, adjust the path automatically so the user doesn't have
		-- add a conditional configuration to the project script.

		local pch = cfg.pchheader
		for _, incdir in ipairs(cfg.includedirs) do
			local testname = path.join(incdir, pch)
			if os.isfile(testname) then
				pch = project.getrelative(cfg.project, testname)
				break
			end
		end

		_x('  PCH = %s', pch)
		_p('  GCH = $(OBJDIR)/$(notdir $(PCH)).gch')
	end


	function make.pchRules(prj)
		_p('ifneq (,$(PCH))')
		_p('.NOTPARALLEL: $(GCH) $(PCH)')
		_p('$(GCH): $(PCH)')
		_p('\t@echo $(notdir $<)')

		local cmd = iif(prj.language == "C", "$(CC) -x c-header $(ALL_CFLAGS)", "$(CXX) -x c++-header $(ALL_CXXFLAGS)")
		_p('\t$(SILENT) %s -o "$@" -MF "$(@:%%.gch=%%.d)" -c "$<"', cmd)

		_p('endif')
		_p('')
	end


	function make.resFlags(cfg, toolset)
		local resflags = table.join(toolset.getdefines(cfg.resdefines), toolset.getincludedirs(cfg, cfg.resincludedirs), cfg.resoptions)
		_p('  ALL_RESFLAGS += $(RESFLAGS) $(DEFINES) $(INCLUDES)%s', make.list(resflags))
	end
