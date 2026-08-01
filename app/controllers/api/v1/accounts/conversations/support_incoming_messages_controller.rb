class Api::V1::Accounts::Conversations::SupportIncomingMessagesController < Api::V1::Accounts::Conversations::BaseController
  wrap_parameters false

  ALLOWED_BODY_KEYS = %w[content gabi_event_ref].freeze
  EVENT_REFERENCE_PATTERN = /\A[A-Za-z0-9_-]{43}\z/

  def create
    return render_forbidden unless allowed_support_request?
    return render_unprocessable('Support incoming messages require an Email inbox') unless email_inbox?
    return render_unprocessable('Invalid support incoming message') unless valid_payload?

    created = false
    @conversation.with_lock do
      @message = existing_message
      unless @message
        @message = @conversation.messages.create!(message_attributes)
        created = true
      end
    end

    render 'api/v1/accounts/conversations/messages/create', status: created ? :created : :ok
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e.record.errors.full_messages.to_sentence)
  end

  private

  def allowed_support_request?
    Current.account_user&.administrator? && support_conversation?
  end

  def support_conversation?
    attributes = @conversation.custom_attributes.to_h
    attributes['support_source_system'] == 'autonomia-support' &&
      attributes['support_source_app_slug'] == 'google-saas'
  end

  def email_inbox?
    @conversation.inbox.channel_type == 'Channel::Email'
  end

  def request_payload
    @request_payload ||= request.request_parameters.to_h
  end

  def valid_payload?
    return false unless request_payload.keys.sort == ALLOWED_BODY_KEYS.sort

    content = request_payload['content']
    event_reference = request_payload['gabi_event_ref']
    content.is_a?(String) && content.length <= 8000 && content.present? &&
      event_reference.is_a?(String) && event_reference.match?(EVENT_REFERENCE_PATTERN)
  end

  def existing_message
    @conversation.messages.find_by(source_id: request_payload['gabi_event_ref'])
  end

  def message_attributes
    {
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      message_type: :incoming,
      content_type: :text,
      content: request_payload['content'],
      private: false,
      sender: @conversation.contact,
      source_id: request_payload['gabi_event_ref'],
      content_attributes: { gabi_event_ref: request_payload['gabi_event_ref'] }
    }
  end

  def render_forbidden
    render json: { error: 'Conversation is not an Autonom.ia support conversation' }, status: :forbidden
  end

  def render_unprocessable(message)
    render json: { error: message }, status: :unprocessable_entity
  end
end
