# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BalanceTransaction, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:contribution) }
    it { is_expected.to belong_to(:user) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:amount) }
    it { is_expected.to validate_presence_of(:event_name) }
    it { is_expected.to validate_presence_of(:user_id) }
    it { is_expected.to validate_inclusion_of(:event_name).in_array(BalanceTransaction::EVENT_NAMES) }
  end

  describe '#insert_contribution_confirmed_after_project_finished' do
    let(:project) { create(:project, goal: 30, state: 'online') }
    let!(:contribution) { create(:confirmed_contribution, value: 200, project: project) }
    let!(:pending_contribution) { create(:pending_contribution, value: 200, project: project, created_at: 20.days.ago) }
    let!(:pending_contribution_2) { create(:pending_contribution, value: 15, project: project, created_at: 22.days.ago) }

    before do
      project.update_attributes(expires_at: 10.days.ago)
      expect(BalanceTransaction).to receive(:insert_successful_project_transactions).with(project.id).and_call_original
      project.finish
    end

    context 'when pending contribution is confirmed after project successful' do
      before do
        expect(BalanceTransaction).to receive(:insert_contribution_confirmed_after_project_finished).with(project.id, pending_contribution.id).and_call_original
        pending_contribution.payments.last.pay
        project.reload
      end

      it 'should create the balance transaction for contribution' do
        bt = pending_contribution.balance_transactions
        expect(bt.where(
          event_name: 'project_contribution_confirmed_after_finished',
          amount: pending_contribution.value
        ).exists?).to eq(true)

        expect(bt.where(
          event_name: 'catarse_contribution_fee',
          amount: (pending_contribution.value * pending_contribution.project.service_fee) * -1
        ).exists?).to eq(true)

        expect(BalanceTransaction).to receive(:insert_contribution_confirmed_after_project_finished).with(project.id, pending_contribution_2.id).and_call_original
        pending_contribution_2.payments.last.pay

        bt = pending_contribution_2.balance_transactions
        expect(bt.where(
          event_name: 'project_contribution_confirmed_after_finished',
          amount: pending_contribution_2.value
        ).exists?).to eq(true)

        expect(bt.where(
          event_name: 'catarse_contribution_fee',
          amount: (pending_contribution_2.value * pending_contribution_2.project.service_fee) * -1
        ).exists?).to eq(true)
      end
    end
  end

  describe 'insert_contribution_chargeback' do
    let!(:confirmed_contribution) { create(:confirmed_contribution) }
    let!(:payment) { confirmed_contribution.payments.last }

    subject { BalanceTransaction.insert_contribution_chargeback(payment.id) }

    context 'when payment is not chargeback' do
      it 'should do nothing' do
        is_expected.to be_nil
      end
    end

    context 'when payment is chargeback' do
      subject { payment.contribution.balance_transactions.last }
      before do
        allow_any_instance_of(Project).to receive(:successful_pledged_transaction).and_return({id: 'mock'})
        payment.chargeback
      end
      it 'should create a balance transaction with negative amount' do
        expect(subject.event_name).to eq('contribution_chargedback')
        expect(subject.user_id).to eq(confirmed_contribution.project.user_id)
        expect(subject.contribution_id).to eq(confirmed_contribution.id)
        expect(subject.amount).to eq(
          (((confirmed_contribution.value) - (confirmed_contribution.value * confirmed_contribution.project.service_fee)) * -1)
        )
      end
    end

    context 'when already have event generated' do
      subject { payment.contribution.balance_transactions.last }
      before do
        allow_any_instance_of(Project).to receive(:successful_pledged_transaction).and_return({id: 'mock'})
        payment.chargeback
      end
      it 'should not create a new transaction' do
        expect(subject.event_name).to eq('contribution_chargedback')
        call_again = BalanceTransaction.insert_contribution_chargeback(payment.id) 
        expect(call_again).to be_nil
      end
    end

    context 'when project is not received the successful project pledged event' do
      subject { BalanceTransaction.insert_contribution_chargeback(payment.id) }

      before do
        allow_any_instance_of(Project).to receive(:successful_pledged_transaction).and_return(nil)
      end

      it { is_expected.to be_nil }

      it 'should not create chargeback on balance' do
        expect(payment.contribution.chargedback_on_balance?).to eq(false)
      end
    end

  end

  describe '#insert_successful_project_transactions' do
    let(:project) { create(:project, goal: 30, state: 'online') }
    let!(:contribution) { create(:confirmed_contribution, value: 20_000, project: project) }

    context 'when given project is finished' do
      before do
        project.update_attributes(expires_at: 2.minutes.ago)
        expect(BalanceTransaction).to receive(:insert_successful_project_transactions).with(project.id).and_call_original
        project.finish
        project.reload
      end

      it 'should create successful_project_pledged transaction' do
        expect(BalanceTransaction.find_by(event_name: 'successful_project_pledged', project_id: project.id, user_id: project.user_id, amount: project.paid_pledged)).not_to be_nil
      end

      it 'should create catarse_project_service_fee transaction' do
        expect(BalanceTransaction.find_by(event_name: 'catarse_project_service_fee', project_id: project.id, user_id: project.user_id, amount: project.total_catarse_fee * -1)).not_to be_nil
      end
    end

    context 'when project owner is pj' do
      before do
        contribution.payments.last.update_attributes(gateway_fee: '400')
        project.user.update_attributes(account_type: 'pj', cpf: '38.414.365/0001-35')
        project.update_attributes(expires_at: 2.minutes.ago)
        project.finish
      end

      it 'should not create irrf_tax_project transaction' do
        expect(BalanceTransaction.find_by(event_name: 'irrf_tax_project', project_id: project.id, user_id: project.user_id, amount: project.irrf_tax)).to be_nil
      end
    end

    context 'when project is not successful yet' do
      let(:project) { create(:project, state: 'online') }
      subject { BalanceTransaction.insert_successful_project_transactions(project.id) }
      it 'should return nothing' do
        is_expected.to eq(nil)
      end
    end
  end

  describe 'insert_contribution_refund' do
    let(:project) { create(:project, goal: 30, state: 'online') }
    let!(:contribution) { create(:confirmed_contribution, value: 200, project: project) }

    context 'when contribution already refunded' do
      before do
        BalanceTransaction.insert_contribution_refund(contribution.id)
      end

      it "should return at second try nil" do
        expect(contribution.balance_refunded?).to eq(true)
        expect(BalanceTransaction.insert_contribution_refund(contribution.id)).to eq(nil)
        expect(BalanceTransaction.where(event_name: 'contribution_refund', contribution_id: contribution.id).count).to eq(1)
      end
    end

    context 'when contributions is not confirmed' do
      before do
        allow(Contribution).to receive(:find).with(contribution.id).and_return(contribution)
        allow(contribution).to receive(:confirmed?).and_return(false)
        expect(contribution).not_to receive(:balance_refunded?)
      end

      it "should return nil" do
        expect(BalanceTransaction.insert_contribution_refund(contribution.id)).to eq(nil)
        expect(BalanceTransaction.where(event_name: 'contribution_refund', contribution_id: contribution.id).count).to eq(0)
      end
    end

    context 'when contribution is avaiable to refund in balance' do
      it "should create balance transaction" do
        balance_transaction = BalanceTransaction.insert_contribution_refund(contribution.id)
        expect(contribution.balance_refunded?).to eq(true)
        expect(balance_transaction.event_name).to eq('contribution_refund')
        expect(balance_transaction.amount).to eq(contribution.value)

      end
    end


  end

  describe 'insert_balance_expired' do
    let!(:transaction) { create(:balance_transaction, event_name: 'contribution_refund', amount: 10.0, created_at: 91.days.ago) }

    subject { BalanceTransaction.insert_balance_expired(transaction.id) }

    context 'when balance transaction is not expired yet' do
      it 'should generate a balance_expired event' do
        expect(subject.event_name).to eq('balance_expired')
        expect(subject.project_id).to eq(transaction.project_id)
        expect(subject.user_id).to eq(transaction.user_id)
        expect(subject.contribution_id).to eq(transaction.contribution_id)
        expect(subject.amount).to eq(transaction.amount * -1)
      end
    end

    context 'when already have a balance transfer events after balance created' do
      before do
        create(:balance_transaction, event_name: event_name, user_id: transaction.user_id)
      end

      context 'when have balance_transfer_request event' do
        let(:event_name) { 'balance_transfer_request' }

        it 'should not generate balance expired event' do
          is_expected.to be_nil
        end
      end

      context 'when have balance_transfer_project event' do
        let(:event_name) { 'balance_transfer_project' }

        it 'should not generate balance expired event' do
          is_expected.to be_nil
        end
      end
    end

    context 'when balance transaction is not over 90 days created' do
      let(:transaction) { create(:balance_transaction, event_name: 'contribution_refund', amount: 10.0, created_at: 10.days.ago) }
      it 'should not generate a balance_expired event' do
        is_expected.to be_nil
      end
    end

    context 'when balance transaction already is expired' do
      before do
        BalanceTransaction.insert_balance_expired(transaction.id)
      end

      it 'should not create balance_expired event' do
        is_expected.to be_nil
      end
    end
  end

  describe 'can_expire_on_balance?' do
    let!(:transaction) { create(:balance_transaction, event_name: 'contribution_refund', amount: 10.0, created_at: 91.days.ago) }

    subject { transaction.can_expire_on_balance? }

    context 'when transaction already over 91 days' do
      it { is_expected.to eq(true) }
    end

    context 'when event is not contribution_refund' do
      let!(:transaction) { create(:balance_transaction, event_name: 'catarse_contribution_fee', amount: 10.0, created_at: 91.days.ago) }
      it { is_expected.to eq(false) }
    end

    context 'when transaction is not over 91 days' do
      let!(:transaction) { create(:balance_transaction, event_name: 'contribution_refund', amount: 10.0, created_at: 70.days.ago) }
      it { is_expected.to eq(false) }
    end

    context 'when transaction have any of balance_transfer events' do
      before do
        create(:balance_transaction, event_name: event_name, user_id: transaction.user_id)
      end

      context 'when have balance_transfer_request event' do
        let(:event_name) { 'balance_transfer_request' }
        it { is_expected.to eq(false) }
      end

      context 'when have balance_transfer_project event' do
        let(:event_name) { 'balance_transfer_project' }
        it { is_expected.to eq(false) }
      end
    end

    context 'when transaction already expired on balance' do
      before do
        create(:balance_transaction, event_name: 'balance_expired', contribution_id: transaction.contribution_id, user_id: transaction.user_id, project_id: transaction.project_id)
      end

      it 'should not create balance_expired event' do
        it { is_expected.to eq(false) }
      end
    end
  end

end
