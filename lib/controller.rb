require 'logger'
require_relative './stages'
require_relative './errors'

##
# Supertype for provisioners.

class BnclController
  ##
  # Just delegate to the configuration object because it has all the pieces to access
  # OpenNebula and perform the necessary comparisons and filtering.
  def action_log
    action_log = Logger.new( '/opt/nebulous/bncl_actions_log', 'daily' )
    action_log.level = Logger::INFO
    @action_log = action_log
  end

  def opennebula_state
    @configuration.opennebula_state
  end

  ##
  # By default the delta is the difference between the configured pool size and what currently exists in OpenNebula
  # but wrappers can override this method which can be used during forking to do the right thing.

  def delta
    required_pool_size = @configuration.count
    actual_pool_size = opennebula_state.length # TODO: Figure out whether we need to filter to just running VMs
    delta = required_pool_size - actual_pool_size
  end

  ##
  # Look at the current delta and generate the required number of forking provisioners.

  def partition(partition_size)
    (1..delta).each_slice(partition_size).map {|slice| forked_provisioner(slice.length)}
  end

  ##
  # Get the state and see if the delta is positive. If the delta is positive then instantiate that
  # many new servers so we can continue with the provisioning process by running the required scripts
  # through SSH. This should return just the VM data because we are going to use SSH to figure out if
  # they are up and running and ready for the rest of the process.

  def instantiate(vm_name_prefix = nil)
    if delta > 0
      STDOUT.puts "Pool delta: pool = #{@configuration.name}, delta = #{delta}."
      @configuration.instantiate!(delta, vm_name_prefix)
    else
      []
    end
  end

  ##
  # Required for most SSH commands.

  def ssh_prefix
    ['ssh', '-o UserKnownHostsFile=/dev/null',
      '-o StrictHostKeyChecking=no', '-o BatchMode=yes', '-o ConnectTimeout=20'].join(' ')
  end

  ##
  # We need to wait until we can reliably make SSH connections to each host and log any errors
  # for the hosts that are unreachable.

  def ssh_ready?(vm_hash)
    ip_address = vm_hash['TEMPLATE']['NIC']['IP']
    raise VMIPError, "IP not found: #{vm_hash}." if ip_address.nil?
    system("#{ssh_prefix} root@#{ip_address} -t 'uptime'")
  end

  ##
  # Look at the configuration and see what kinds of provisioning stages there are and
  # generate commands accordingly. Each stage can have multiple commands.

  def stages(controll_stages)
    controll_stages.each_with_index.map {|stage, index| Stages.from_config(stage, index)}
  end

  def run(vm_hashes)
    vms_left = vm_hashes.length
    action_log.info "About to provision #{vms_left} machines"
    ssh_action = lambda do |vm_hash|
      if ssh_ready?(vm_hash)
        final_commands = generate_ssh_commands(vm_hash)
        return system(final_commands)
      else
        return false;
      end
    end
    accumulator = []
    vm_hashes.each do |vm_hash|
      counter = 0
      while !ssh_action.call(vm_hash)
        counter += 1
        tries_left = 60 - counter
        action_log.info "Couldn't connect to agent  #{vm_hash['NAME']}. Will try #{tries_left} more times"
        break if counter > 60
        sleep 5
      end
      if counter < 61
        vms_left = vms_left - 1
        action_log.info "VM just provisioned: #{vm_hash['NAME']}."
        STDOUT.puts "Number of vms left to provision: #{vms_left}."
        accumulator << vm_hash
      else
        action_log.error "Unable to provision VM: #{vm_hash}."
      end
    end
    if vms_left != 0
      action_log.error "ERROR: Failed to provision #{vms_left} vms."
    else
      action_log.info "Successfully provisioned #{accumulator.length} vms."
    end
    accumulator
  end

end
