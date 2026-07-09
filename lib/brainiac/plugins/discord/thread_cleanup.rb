# frozen_string_literal: true

require "open3"
require "fileutils"

module Brainiac
  module Plugins
    module Discord
      # Handles cleanup of Discord thread worktrees when threads are archived or deleted.
      #
      # When a thread is archived (manually closed or auto-archived due to inactivity)
      # or deleted, this module looks up the associated worktree in discord_thread_map.json,
      # verifies it has no uncommitted changes, removes the worktree + branch, and removes
      # the thread map entry.
      module ThreadCleanup
        class << self
          def handle_archive(data, agent_key, agent_display)
            thread_id = data["id"]
            return unless thread_id

            thread_map_key = "#{agent_key}:#{thread_id}"

            entry = Config.thread_map_mutex.synchronize do
              map = Config.load_thread_map
              map[thread_map_key]
            end

            unless entry
              LOG.info "[Discord:#{agent_display}] Thread #{thread_id} archived — no worktree tracked, nothing to clean up" if defined?(LOG)
              return
            end

            worktree_path = entry["worktree"]
            branch = entry["branch"]
            project_key = entry["project"]
            chat_mode = entry["chat_mode"]

            if chat_mode
              cleanup_chat_mode_dir(worktree_path, thread_map_key, agent_display, thread_id)
            else
              cleanup_worktree(worktree_path, branch, project_key, thread_map_key, agent_display, thread_id)
            end
          end

          private

          def cleanup_chat_mode_dir(dir_path, thread_map_key, agent_display, thread_id)
            if dir_path && File.directory?(dir_path)
              FileUtils.rm_rf(dir_path)
              LOG.info "[Discord:#{agent_display}] Thread #{thread_id} archived — removed chat mode dir #{dir_path}" if defined?(LOG)
            elsif defined?(LOG)
              LOG.info "[Discord:#{agent_display}] Thread #{thread_id} archived — chat mode dir already gone"
            end

            remove_thread_map_entry(thread_map_key)
          end

          def cleanup_worktree(worktree_path, branch, project_key, thread_map_key, agent_display, thread_id)
            unless worktree_path && File.directory?(worktree_path)
              LOG.info "[Discord:#{agent_display}] Thread #{thread_id} archived — worktree already removed, cleaning up map entry" if defined?(LOG)
              remove_thread_map_entry(thread_map_key)
              return
            end

            status_output, = Open3.capture3("git", "status", "--porcelain", chdir: worktree_path)
            unless status_output.strip.empty?
              if defined?(LOG)
                LOG.warn "[Discord:#{agent_display}] Thread #{thread_id} archived — " \
                         "worktree #{worktree_path} has uncommitted changes, skipping cleanup"
              end
              return
            end

            project_config = defined?(PROJECTS) ? PROJECTS[project_key] : nil
            repo_path = project_config&.dig("repo_path")

            unless repo_path && File.directory?(repo_path)
              if defined?(LOG)
                LOG.warn "[Discord:#{agent_display}] Thread #{thread_id} archived — " \
                         "cannot find repo for project '#{project_key}', removing directory directly"
              end
              FileUtils.rm_rf(worktree_path)
              remove_thread_map_entry(thread_map_key)
              return
            end

            begin
              Open3.capture3("git", "worktree", "remove", worktree_path, "--force", chdir: repo_path)
              LOG.info "[Discord:#{agent_display}] Thread #{thread_id} archived — removed worktree #{worktree_path}" if defined?(LOG)
            rescue StandardError => e
              LOG.warn "[Discord:#{agent_display}] Failed to remove worktree #{worktree_path}: #{e.message}" if defined?(LOG)
            end

            if branch
              begin
                Open3.capture3("git", "branch", "-D", branch, chdir: repo_path)
                LOG.info "[Discord:#{agent_display}] Thread #{thread_id} archived — deleted branch #{branch}" if defined?(LOG)
              rescue StandardError => e
                LOG.warn "[Discord:#{agent_display}] Failed to delete branch #{branch}: #{e.message}" if defined?(LOG)
              end
            end

            remove_thread_map_entry(thread_map_key)
          end

          def remove_thread_map_entry(thread_map_key)
            Config.thread_map_mutex.synchronize do
              map = Config.load_thread_map
              map.delete(thread_map_key)
              Config.save_thread_map(map)
            end
          end
        end
      end
    end
  end
end
