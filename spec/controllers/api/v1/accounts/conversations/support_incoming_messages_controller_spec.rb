require 'rails_helper'

RSpec.describe 'Support Incoming Messages API', type: :request do
  include ActiveJob::TestHelper

  let!(:account) { create(:account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:email_channel) { create(:channel_email, account: account) }
  let!(:email_inbox) { email_channel.inbox }
  let!(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: email_inbox,
      custom_attributes: {
        'support_source_system' => 'autonomia-support',
        'support_source_app_slug' => 'google-saas',
        'support_source_ticket_id' => SecureRandom.uuid
      }
    )
  end
  let(:event_ref) { 'a' * 43 }
  let(:request_path) do
    "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/support_incoming_messages"
  end
  let(:valid_params) { { content: 'Mensagem enviada pelo portal', gabi_event_ref: event_ref } }

  before do
    create(:inbox_member, inbox: email_inbox, user: agent)
  end

  it 'requires authentication' do
    post request_path, params: valid_params, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(conversation.messages).to be_empty
  end

  it 'creates a public incoming message sent by the conversation contact' do
    post request_path, params: valid_params, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:created)
    message = conversation.messages.sole
    expect(response.parsed_body['id']).to eq(message.id)
    expect(message).to be_incoming
    expect(message).not_to be_private
    expect(message.sender).to eq(conversation.contact)
    expect(message.content).to eq(valid_params[:content])
    expect(message.content_attributes['gabi_event_ref']).to eq(event_ref)
  end

  it 'returns the existing message when the event reference is replayed' do
    headers = agent.create_new_auth_token

    post request_path, params: valid_params, headers: headers, as: :json
    first_id = response.parsed_body['id']
    post request_path, params: valid_params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(first_id)
    expect(conversation.messages.count).to eq(1)
  end

  it 'creates a second message for a different event reference' do
    headers = agent.create_new_auth_token

    post request_path, params: valid_params, headers: headers, as: :json
    post request_path,
         params: valid_params.merge(gabi_event_ref: 'b' * 43),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(conversation.messages.count).to eq(2)
  end

  it 'does not send an email for the incoming message' do
    expect(ConversationReplyMailer).not_to receive(:with)

    perform_enqueued_jobs(only: SendReplyJob) do
      post request_path, params: valid_params, headers: agent.create_new_auth_token, as: :json
    end

    expect(response).to have_http_status(:created)
  end

  it 'rejects a normal conversation without the support attributes' do
    conversation.update!(custom_attributes: {})

    post request_path, params: valid_params, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(conversation.messages).to be_empty
  end

  it 'rejects a conversation for another source app' do
    conversation.update!(custom_attributes: conversation.custom_attributes.merge('support_source_app_slug' => 'other-saas'))

    post request_path, params: valid_params, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(conversation.messages).to be_empty
  end

  it 'rejects a support conversation outside an email inbox' do
    widget_inbox = create(:inbox, account: account)
    widget_conversation = create(
      :conversation,
      account: account,
      inbox: widget_inbox,
      custom_attributes: conversation.custom_attributes
    )
    create(:inbox_member, inbox: widget_inbox, user: agent)

    post "/api/v1/accounts/#{account.id}/conversations/#{widget_conversation.display_id}/support_incoming_messages",
         params: valid_params,
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(widget_conversation.messages).to be_empty
  end

  it 'rejects invalid content, references and unexpected body fields' do
    headers = agent.create_new_auth_token
    invalid_payloads = [
      valid_params.merge(content: ''),
      valid_params.merge(content: 'x' * 8001),
      valid_params.merge(content: "#{' ' * 8000}x"),
      valid_params.merge(gabi_event_ref: 'not-a-real-reference'),
      valid_params.merge(private: true)
    ]

    invalid_payloads.each do |payload|
      post request_path, params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(conversation.messages).to be_empty
  end

  it 'preserves account isolation' do
    other_account = create(:account)
    other_channel = create(:channel_email, account: other_account)
    other_conversation = create(
      :conversation,
      account: other_account,
      inbox: other_channel.inbox,
      custom_attributes: conversation.custom_attributes
    )

    post "/api/v1/accounts/#{other_account.id}/conversations/#{other_conversation.display_id}/support_incoming_messages",
         params: valid_params,
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).not_to have_http_status(:success)
    expect(other_conversation.messages).to be_empty
  end
end
