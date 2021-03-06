require 'bunny'

class Woodhouse::Runners::BunnyRunner < Woodhouse::Runner
  include Celluloid

  def subscribe
    bunny = Bunny.new(@config.server_info)
    bunny.start
    channel = bunny.create_channel
    channel.prefetch(1)
    queue = channel.queue(@worker.queue_name)
    exchange = channel.exchange(@worker.exchange_name, :type => :headers)
    queue.bind(exchange, :arguments => @worker.criteria.amqp_headers)
    worker = Celluloid.current_actor
    queue.subscribe(:ack => true, :block => false) do |delivery, props, payload|
      begin
        job = make_job(props, payload)
        if can_service_job?(job)
          if service_job(job)
            channel.acknowledge(delivery.delivery_tag, false)
          else
            channel.reject(delivery.delivery_tag, false)
          end
        else
          @config.logger.error("Cannot service job #{job.describe} in queue for #{@worker.describe}")
          channel.reject(delivery.delivery_tag, false) 
        end
      rescue => err
        begin
          @config.logger.error("Error bubbled up out of worker. This shouldn't happen. #{err.message}")
          err.backtrace.each do |btr|
            @config.logger.error("  #{btr}")
          end
          # Don't risk grabbing this job again. 
          channel.reject(delivery.delivery_tag, false)
        ensure
          worker.bail_out(err)
        end
      end
    end
    wait :spin_down
  end

  def bail_out(err)
    raise Woodhouse::BailOut, "#{err.class}: #{err.message}"
  end

  def spin_down
    signal :spin_down
  end

  def make_job(properties, payload)
    Woodhouse::Job.new(@worker.worker_class_name, @worker.job_method) do |job|
      args = properties.headers
      job.arguments = args
      job.payload = payload
    end
  end

end
