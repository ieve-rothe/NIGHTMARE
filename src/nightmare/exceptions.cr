class SecurityError < Exception
end

module Nightmare
  alias SecurityError = ::SecurityError

  class Error < Exception
  end

  class ConfigurationError < Error
  end
end
