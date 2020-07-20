require 'semver'
require 'distribution'
require 'yaml'
require 'logger'
require 'awesome_print'
require 'deep_dive'
require 'queue_ding'

=begin rdoc
= RubyNEAT -- a Ruby Implementation of the Neural Evolution of Augmenting Topologies.

The RubyNEAT system incorporates the basis of the NEAT algorithm. Flexibility
is the key here, allowing RubyNEAT to be leverage in a variety of applications.
=end

if $log.nil?
  $log = Logger.new(STDOUT)
  $log.level = Logger::INFO
end
AwesomePrint.defaults = { plain: true }

=begin rdoc
= NEAT -- Module for RubyNEAT.

== Synopsis
We have a Population of Critters, and each Critter
represents a network of Neurons and a connection list specifying
how those Neurons are connected.

Each Neuron has an implicit genotype and phenotype component. Neurons,
from the Ruby perspective, contain their own code to produce their own
phenotypes. 

There are input Neurons and output Neurons. The input Neurons are special, as
they do not contain any input from other nodes, but serve as interfaces
from the "real world". Their range of inputs are open, and it shall be up to
the input Neuron's phenotype generators to condition those inputs, if need be,
to something more suitable for the neural network.

== Issues
=== Multicore / Cloud Computing
Some thought needs to be given to how to make this amenable to multiple
processes so that we can leverage the power of multicore systems as well
as multiple computers in the Cloud, etc.

Our initial inclination  is to put all of that functionality in the Controller.

== Uniquely Generated Named Objects (UGNOs)
Every RubyNEAT Object instance is assigned a unique name generated randomly.
The name has no other significance other than to uniquely identify the object.

We have chosen the names of the letters of various alphabets to be the core
of those names. The list may be subject to change until we are out of alpha,
then will be set in quick drying concrete.
=end
module NEAT
  @rng_count = 0
  @rng_names = %w{alpha beta gamma delta epsilon zeta  eta theta kappa lambda
                  mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega

                  alef bet gimel dalet he vav zayin het tet yod kaf lamed
                  mem nun samekh ayin pe tsadi qof resh shin tav

                  pop wo sip zotz sek xul yaxkin mol chen yax sak kej mak kankin
                  muwan pax kayab kumku wayeb

                  ki gi ngi ti di ni bi mi yi li wi si hi ku gu ngu tu du pu
                  bu yu lu wu su hu

                  ha jim theh teh beh alif sin zin ra dhal dal kha ain dha ta
                  dad sad shin mim lam kaf qaf feh ghain yeh waw heh nun}
  def self.random_name_generator
    (1..3).map {
      @rng_names[rand @rng_names.size]
    }.push(@rng_count += 1).join('_').to_sym
  end

  # Name of the stimulus method in NEAT::Critter::Phenotype to use
  # for the singleton method expression of the critter.
  STIMULUS = :stimulate

  # Mixin for new innovation numbers.
  def self.new_innovation; @controller.new_innovation; end

  # Mixin for the gaussian object.
  def self.gaussian ; @controller.gaussian; end

  # PrettyPrint to log.debug
  def self.dpp ob
    #$log.ap ob
  end

  # Basis of all NEAT objects.
  # NeatOb has support for NEAT attributes with
  # special support for hooks and queues.
  class NeatOb
    include DeepDive
    extend QueueDing

    exclude :controller, :name

    # Designation of this particular object instance
    attr_reader :name

    # Who's your daddy?
    attr_reader :controller

    def log ; $log ; end
    def self.log ; $log; end

    # Initializer for all NEAT objects. Requires that
    # the controller object is specified for all classes
    # with the exception of the Controller itself or the
    # Controller's NeatSettings.
    def initialize(controller = nil, name = nil)
      @name = unless name.nil?
                name.to_sym
              else
                NEAT::random_name_generator
              end
      unless controller.nil?
        @controller = controller
      else
        raise NeatException.new "Controller Needed!" unless self.is_a?(Controller) or self.is_a?(Controller::NeatSettings)
        @controller = self unless self.is_a? Controller::NeatSettings
      end
    end

    def to_s
      "%s<%s>" % [self.class, self.name]
    end


    class << self
      # Defaultable attributes of neat attributes.
      #
      # If hooks: true is given, two hook functions are
      # created:
      ## <sym>_add() -- add a hook
      ## <sym>_set() -- set a hook, overwriting all other hooks set or added.
      ## <sym>_clear -- clear all hooks
      ## <sym>_none? -- return true if no hooks are defined.
      ## <sym>_one? -- return true if exactly hook is defined.
      ## <sym>_hook() -- for passing unnamed parameters to a singular hook.
      ## <sym>_np_hook() -- for passing unnamed parameters to a singular hook.
      ## <sym>_hook_itself() -- for getting the proc reference to the hook.
      ## <sym>_hooks() -- for passing unnamed parameters.
      ## <sym>_np_hooks() -- for passing a named parameter list.
      #
      # For *_hook(), the function returns the single result.
      # For *_hooks(), the hook function return an array of results
      # from all the actual registered hooks called.
      def attr_neat(sym,
                    default: nil,
                    cloneable: nil,
                    hooks: false,
                    queue: false)
        svar = "@#{sym}"

        # Guess what clonable should be.
        # This is meant to cover "90%" of the cases.
        cloneable = case
                      when default.nil?
                        false
                      when default.kind_of?(Numeric)
                        false
                      else
                        true
                    end if cloneable.nil?

        # Sanity checks
        raise NeatException("Both hooks and queue cannot both be set for #{sym}.") if hooks and queue
        raise NeatException("Defaults cannot be defined for hooks and queues for #{sym}.") if (hooks or queue) and not default.nil?

        if hooks
          default = []
          cloneable = true
          hook_setup sym
        end

        if queue
          default = QDing.new
          cloneable = true
          queue_setup sym
        end

        define_method("#{sym}=") do |v|
          instance_variable_set(svar, v)
        end unless hooks or queue

        # TODO: Enhance this getter method for performance.
        define_method(sym) do
          instance_variable_set(svar,
                                instance_variable_get(svar) ||
                                    ((cloneable) ? default.clone
                                                 : default))
        end
      end

      private
      def hook_setup(sym)
        define_method("#{sym}_add") do |&hook|
          send(sym) << hook
        end

        define_method("#{sym}_set") do |&hook|
          send(sym).clear
          send(sym) << hook
        end

        define_method("#{sym}_clear") do
          send(sym).clear
        end

        define_method("#{sym}_none?") do
          send(sym).empty?
        end

        define_method("#{sym}_one?") do
          send(sym).size == 1
        end

        # hooks with named parameters
        define_method("#{sym}_np_hooks") do |**hparams|
          send(sym).map{|funct| funct.(**hparams)}
        end

        # hooks with traditional parameters
        define_method("#{sym}_hooks") do |*params|
          send(sym).map{|funct| funct.(*params)}
        end

        # TODO: DRY up the following functions, which does size checking in exacly the same way.
        # Single hook with named parameters
        define_method("#{sym}_np_hook") do |**hparams|
          sz = send(sym).size
          raise NeatException.new("#{sym}_np_hook must have exactly one hook (#{sz})") unless sz == 1
          send(sym).map{|funct| funct.(**hparams)}.first
        end

        # Single hook with traditional parameters
        define_method("#{sym}_hook") do |*params|
          sz = send(sym).size
          raise NeatException.new("#{sym}_hook must have exactly one hook (#{sz})") unless sz == 1
          send(sym).map{|funct| funct.(*params)}.first
        end

        # Get the singular hook function
        define_method("#{sym}_hook_itself") do
          sz = send(sym).size
          raise NeatException.new("#{sym}_hook_itself must have exactly one hook (#{sz})") unless sz == 1
          send(sym).first
        end
      end

      def queue_setup(sym)
        # Add boilerplate code for queues here.
      end
    end
  end

  class NeatException < Exception
  end

  #= Base class of operators in RubyNEAT,
  # Such as Evolver, etc.
  class Operator < NeatOb
  end

  #= Traits
  # A Trait is a group of parameters that can be expressed     
  # as a group more than one time.  Traits save a genetic      
  # algorithm from having to search vast parameter landscapes  
  # on every node.  Instead, each node can simply point to a trait 
  # and those traits can evolve on their own. (Taken from the C version of NEAT)
  #
  # Since we wish to allow for different classes of Neurons, this trait idea is
  # super, since all we need to do is have a different trait species for the
  # different node types.
  class Trait < NeatOb
  end

  require 'rubyneat/critter'
  require 'rubyneat/neuron'
  require 'rubyneat/population'
  require 'rubyneat/evolver'
  require 'rubyneat/expressor'
  require 'rubyneat/evaluator'

  #= Controller for all operations of RubyNEAT
  # This object contains all the specifications and details for
  # evolving and evaluation of the RubyNEAT system.  It is 
  # a type of "World", if you will, for the entire enterprise.
  #
  # Your application shall only have one Controller.
  #
  # FIXME: The function hooks really should be able to take more
  # FIXME: than one hook! we don't need that functionality right
  # FIXME: now. Also, the Controller 'god' object itself will need
  # FIXME: to undergo some refactorization so that we can have many
  # FIXME: of them for HyperNEAT, co-evolution, etc.
  #
  # FIXME: An alternative approach would be to have demigod objects
  # FIXME: where the controller would lord it over them all. Attention
  # FIXME: must also be given to Rubinius and JRuby so that we can
  # FIXME: run under multiple cores.
  class Controller < NeatOb
    # Version of RubyNEAT runing
    attr_neat :version, default: SemVer.find(SEMVER_PATH).format("%M.%m.%p%s")
    attr_neat :neater, default: '--unspecified--'

    # global innovation number
    attr_neat :glob_innov_num, default: 0, cloneable: false

    # current sequence number being evaluated
    attr_reader :seq_num

    # Current generation count
    attr_reader :generation_num

    # catalog of neurons classes to use { weight => nclass, ... }
    attr_accessor :neuron_catalog

    # Class map of named input and output neurons (each critter will have 
    # instantiations of these) name: InputNeuralClass (usually InputNeuron)
    attr_accessor :neural_inputs, :neural_outputs, :neural_hidden

    # Parameters for evolution (NeatParameters)
    attr_accessor :parms

    # population object and class specification
    attr_reader :population, :population_history, :population_class

    attr_accessor :expressor, :expressor_class 
    attr_accessor :evaluator, :evaluator_class
    attr_accessor :evolver, :evolver_class

    # Global verbosity level:
    ## 1 - normal (the default)
    ## 2 - really verbose
    ## 3 - maximally verbose
    # Use in conjunction with log.debug
    attr_neat :verbosity,        default: 1

    # Query function that Critters shall call.
    attr_neat :query_func,       hooks: true

    # Fitness function that Critters shall be rated on.
    attr_neat :fitness_func,     hooks: true

    # Recurrence function that Critters will yield to.
    attr_neat :recurrence_func,  hooks: true

    # Compare function for fitness
    # Cost function for integrating in the cost to the fitness scalar.
    attr_neat :compare_func,     hooks: true
    attr_neat :cost_func,        hooks: true
    attr_neat :stop_on_fit_func, hooks: true

    # End run function to call at the end of each generational run
    # Also report_hook to dump reports for the user, etc.
    attr_neat :end_run,          hooks: true
    attr_neat :report,           hooks: true

    # Hook to handle pre_exit functionality
    attr_neat :pre_exit,         hooks: true

    # Logger object for all of RubyNEAT
    attr_reader :log

    # Various parameters affecting evolution.
    # Based somewhat on the Ken Stanley C version of NEAT.
    # TODO not all of these parameters are implemented yet!!!
    class NeatSettings < NeatOb
      ## RubyNEAT specific
      
      # Set to true to returned named parameters as hashes to the fitness function
      # (the default is to do ordered arrays)
      attr_accessor :hash_on_fitness

      ## based on the C version of NEAT
      attr_accessor :age_significance
      attr_accessor :babies_stolen

      # Species compatability threshold
      attr_accessor :compatibility_threshold

      # Speciation coffficient
      attr_accessor :disjoint_coefficient, :excess_coefficient, :weight_coefficient
      
      # Max target number of species (will result in the compatability_coeifficient
      # being adjusted automatically
      attr_accessor :max_species

      # Species Peality age for not making progress
      attr_accessor :dropoff_age

      # Species smallest population allowed (coalse smaller species into one)
      attr_accessor :smallest_species

      # Ratio of mating are actually interspecies
      attr_accessor :interspecies_mate_rate

      attr_accessor :linktrait_mutation_sig
      attr_accessor :mate_multipoint_avg_prob
      attr_accessor :mate_multipoint_prob
      attr_accessor :mate_only_prob
      attr_accessor :mate_singlepoint_prob

      # Maximum number of generations to run, if given.
      attr_neat :max_generations, default: 1000

      # Maximum number of populations to maintain in the history buffer.
      attr_neat :max_population_history, default: 10

      attr_accessor :mutate_add_gene_prob
      attr_accessor :mutate_add_neuron_prob

      attr_accessor :mutate_gene_disable_prob
      attr_accessor :mutate_gene_reenable_prob

      attr_accessor :mutate_gene_trait_prob

      # For gene weights perturbations and changes (complete overwrites)
      attr_accessor :mutate_perturb_gene_weights_prob, 
                    :mutate_perturb_gene_weights_sd,
                    :mutate_change_gene_weights_prob,
                    :mutate_change_gene_weights_sd

      attr_accessor :mutate_neuron_trait_prob
      attr_accessor :mutate_only_prob
      attr_accessor :mutate_random_trait_prob
      attr_accessor :mutate_toggle_enable_prob
      attr_accessor :mutdiff_coefficient
      attr_accessor :newlink_tries
      attr_accessor :neuron_trait_mut_sig

      # fitness costs, if given, use in the computation of fitness
      # AFTER the overall fitness for the applied stimuli have been
      # calculated.
      attr_accessor :fitness_cost_per_neuron
      attr_accessor :fitness_cost_per_gene

      # If set, will start off at the specified size and 
      # grow to the bigger population size
      attr_accessor :start_population_size, :population_size

      attr_neat :start_sequence_at, default: 0
      attr_neat :end_sequence_at,   default: 100

      attr_accessor :print_every
      attr_accessor :recur_only_prob
      attr_accessor :recur_prob

      # factor (0 to 1) of the top percentage of the species that's
      # allowed to mate.
      attr_accessor :survival_threshold
      attr_accessor :survival_mininum_per_species

      attr_accessor :trait_mutation_power
      attr_accessor :trait_param_mut_prob
      attr_accessor :weigh_mut_power

      # Enable FS-NEAT
      attr_accessor :feature_selection_switch

      # Enable HyperNEAT. This will result in the critters
      # being interpreted as CPPNs for substrate weights. Additional
      # setup will be necessary.
      attr_accessor :hyper_switch

      # Enable Evolved Substrate HyperNEAT. Meaningless unless
      # hyper_switch is also enabled.
      attr_accessor :evolved_substrate_switch

      # Enable RT-NEAT, for gradual evolution suitable for
      # games and other human-interactive systems.
      attr_accessor :real_time_switch

      # If true, allow for recurrent networks.
      attr_accessor :recurrency_switch

      # Set up defaults for mandatory entries.
      def initialize
        super
        # Default operators
        @evaluator = Evaluator.new self
        @expressor = Expressor.new self
        @evolver = Evolver.new self
      end
    end

    #- neural_inputs -- array of input classes
    #- neural_outputs -- array of output classes
    #- parameters -- NeatParameters object, or a path to a YAML file to create this.
    def initialize(neural_inputs: nil,
                   neural_outputs: nil,
                   neural_hidden: nil,
                   parameters: NeatSettings.new,
                      &block)
      super(self)
      @gaussian = Distribution::Normal.rng
      @population_history = []
      @evolver = Evolver.new self
      @expressor = Expressor.new self

      @neuron_catalog = Neuron::neuron_types.clone
      @neural_inputs  = neural_inputs
      @neural_outputs = neural_outputs
      @neural_hidden  = neural_hidden

      # Default classes for population and operators, etc.
      @population_class = NEAT::Population
      @evaluator_class = NEAT::Evaluator
      @expressor_class = NEAT::Expressor
      @evolver_class = NEAT::Evolver

      # Handle the parameters parameter. :-)
      @parms = unless parameters.kind_of? String
                 parameters
               else # load it from a file
                 open(parameters, 'r') { |fd| YAML::load fd.read }
               end
      block.(self) unless block.nil?
    end

    def new_innovation ; self.glob_innov_num += 1 ; end
    def gaussian ; @gaussian.() ; end

    # Run this evolution.
    def run
      pre_run_initialize
      (1..@parms.max_generations).each do |gen_number|
        @generation_num = gen_number # must be set first
        @population_history << unless @population.nil?
                                 @population
                               else
                                 @population = @population_class.new(self)
                               end
        @population.generation = gen_number
        @population_history.shift unless @population_history.size <= @parms.max_population_history
        @population.mutate!
        @population.express!

        ## Evaluate population
        @evaluator.ready_for_evaluation @population
        (@parms.start_sequence_at .. @parms.end_sequence_at).each do |snum|
          @seq_num = snum
          @population.evaluate!
        end

        @population.analyze!
        @population.speciate!

        $log.debug @population.dump_s unless self.verbosity < 3

        new_pop = @population.evolve

        ## Report hook for evaluation
        report_hooks(@population.report)

        ## Exit if fitness criteria is reached
        #FIXME handle this exit condition better!!!!!
        exit_neat if stop_on_fit_func_hook(@population.report.last[:fitness], self) unless stop_on_fit_func_none?

        ## Evolve population
        @population = new_pop

        ## Finish up this run
        end_run_hooks(self)
      end
    end

    private
    # We must set up the objects we need prior to the run, if not set.
    def pre_run_initialize
      @evaluator = @evaluator_class.new(self) if @evaluator.nil?
      @evolver = @evolver_class.new(self) if @evolver.nil?
    end

    # Allow us to hook in pre-exit functionality here
    # This function shall never return.
    def exit_neat
      pre_exit_hook(self) unless pre_exit_none?
      exit
    end
  end

  @controller = Controller.new
  def self.controller ; @controller ; end
  def self.controller=(controller) ; @controller = controller ; end
  def self.create_controller(*parms); @controller = Controller.new(*parms); end
end

# We put all the internal requires at the end to avoid conflicts.
require_relative 'neuron'
require_relative 'population'
